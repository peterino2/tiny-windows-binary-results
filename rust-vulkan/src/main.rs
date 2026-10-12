#![windows_subsystem = "windows"]
use ash::{vk, Entry, extensions::khr::{Surface, Win32Surface, Swapchain}};
use std::{ffi::CString, io::Cursor};
use windows::{core::w, Win32::{Foundation::*, System::{LibraryLoader::GetModuleHandleW, Threading::Sleep}, UI::WindowsAndMessaging::*}};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_CLOSE | WM_DESTROY => { PostQuitMessage(0); LRESULT(0) }
        WM_KEYDOWN if wp.0 == 27 => { PostQuitMessage(0); LRESULT(0) }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}
struct Window(HWND);
impl Drop for Window { fn drop(&mut self) { unsafe { let _ = DestroyWindow(self.0); } } }
struct SwapResources {
    swap: vk::SwapchainKHR, extent: vk::Extent2D, views: Vec<vk::ImageView>,
    pass: vk::RenderPass, pipeline: vk::Pipeline, frames: Vec<vk::Framebuffer>, finished: Vec<vk::Semaphore>,
}
unsafe fn destroy_swap(device: &ash::Device, loader: &Swapchain, r: &SwapResources) {
    for &s in &r.finished { device.destroy_semaphore(s, None); }
    for &f in &r.frames { device.destroy_framebuffer(f, None); }
    device.destroy_pipeline(r.pipeline, None); device.destroy_render_pass(r.pass, None);
    for &v in &r.views { device.destroy_image_view(v, None); }
    loader.destroy_swapchain(r.swap, None);
}
unsafe fn create_swap(device: &ash::Device, physical: vk::PhysicalDevice, surface_api: &Surface,
    surface: vk::SurfaceKHR, swap_api: &Swapchain, layout: vk::PipelineLayout) -> Result<SwapResources> {
    let caps = surface_api.get_physical_device_surface_capabilities(physical, surface)?;
    let formats = surface_api.get_physical_device_surface_formats(physical, surface)?;
    let mut format = *formats.iter().find(|f| f.format == vk::Format::B8G8R8A8_UNORM && f.color_space == vk::ColorSpaceKHR::SRGB_NONLINEAR)
        .or_else(|| formats.first()).ok_or("No surface formats")?;
    if format.format == vk::Format::UNDEFINED { format.format = vk::Format::B8G8R8A8_UNORM; }
    let extent = if caps.current_extent.width == u32::MAX {
        vk::Extent2D { width: 800u32.clamp(caps.min_image_extent.width, caps.max_image_extent.width),
            height: 600u32.clamp(caps.min_image_extent.height, caps.max_image_extent.height) }
    } else { caps.current_extent };
    let mut count = 2.max(caps.min_image_count);
    if caps.max_image_count != 0 { count = count.min(caps.max_image_count); }
    let alpha = [vk::CompositeAlphaFlagsKHR::OPAQUE, vk::CompositeAlphaFlagsKHR::PRE_MULTIPLIED,
        vk::CompositeAlphaFlagsKHR::POST_MULTIPLIED, vk::CompositeAlphaFlagsKHR::INHERIT].into_iter()
        .find(|a| caps.supported_composite_alpha.contains(*a)).ok_or("No composite alpha mode")?;
    let swap = swap_api.create_swapchain(&vk::SwapchainCreateInfoKHR::builder().surface(surface)
        .min_image_count(count).image_format(format.format).image_color_space(format.color_space)
        .image_extent(extent).image_array_layers(1).image_usage(vk::ImageUsageFlags::COLOR_ATTACHMENT)
        .image_sharing_mode(vk::SharingMode::EXCLUSIVE).pre_transform(caps.current_transform)
        .composite_alpha(alpha).present_mode(vk::PresentModeKHR::FIFO).clipped(true), None)?;
    let images = swap_api.get_swapchain_images(swap)?;
    let mut views = Vec::new();
    for image in images {
        views.push(device.create_image_view(&vk::ImageViewCreateInfo::builder().image(image)
            .view_type(vk::ImageViewType::TYPE_2D).format(format.format)
            .subresource_range(vk::ImageSubresourceRange { aspect_mask: vk::ImageAspectFlags::COLOR,
                base_mip_level: 0, level_count: 1, base_array_layer: 0, layer_count: 1 }), None)?);
    }
    let attachments = [vk::AttachmentDescription::builder().format(format.format).samples(vk::SampleCountFlags::TYPE_1)
        .load_op(vk::AttachmentLoadOp::CLEAR).store_op(vk::AttachmentStoreOp::STORE)
        .stencil_load_op(vk::AttachmentLoadOp::DONT_CARE).stencil_store_op(vk::AttachmentStoreOp::DONT_CARE)
        .initial_layout(vk::ImageLayout::UNDEFINED).final_layout(vk::ImageLayout::PRESENT_SRC_KHR).build()];
    let color = [vk::AttachmentReference { attachment: 0, layout: vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL }];
    let subpasses = [vk::SubpassDescription::builder().pipeline_bind_point(vk::PipelineBindPoint::GRAPHICS).color_attachments(&color).build()];
    let dependencies = [vk::SubpassDependency::builder().src_subpass(vk::SUBPASS_EXTERNAL).dst_subpass(0)
        .src_stage_mask(vk::PipelineStageFlags::COLOR_ATTACHMENT_OUTPUT).dst_stage_mask(vk::PipelineStageFlags::COLOR_ATTACHMENT_OUTPUT)
        .dst_access_mask(vk::AccessFlags::COLOR_ATTACHMENT_WRITE).build()];
    let pass = device.create_render_pass(&vk::RenderPassCreateInfo::builder().attachments(&attachments).subpasses(&subpasses).dependencies(&dependencies), None)?;
    let vs_code = ash::util::read_spv(&mut Cursor::new(include_bytes!("../../hello-vulkan/src/triangle.vert.spv")))?;
    let ps_code = ash::util::read_spv(&mut Cursor::new(include_bytes!("../../hello-vulkan/src/triangle.frag.spv")))?;
    let vs = device.create_shader_module(&vk::ShaderModuleCreateInfo::builder().code(&vs_code), None)?;
    let ps = device.create_shader_module(&vk::ShaderModuleCreateInfo::builder().code(&ps_code), None)?;
    let name = CString::new("main")?;
    let stages = [vk::PipelineShaderStageCreateInfo::builder().stage(vk::ShaderStageFlags::VERTEX).module(vs).name(&name).build(),
        vk::PipelineShaderStageCreateInfo::builder().stage(vk::ShaderStageFlags::FRAGMENT).module(ps).name(&name).build()];
    let vertex = vk::PipelineVertexInputStateCreateInfo::default();
    let assembly = vk::PipelineInputAssemblyStateCreateInfo::builder().topology(vk::PrimitiveTopology::TRIANGLE_LIST);
    let viewports = [vk::Viewport { x: 0.0, y: 0.0, width: extent.width as f32, height: extent.height as f32, min_depth: 0.0, max_depth: 1.0 }];
    let scissors = [vk::Rect2D { offset: vk::Offset2D::default(), extent }];
    let viewport = vk::PipelineViewportStateCreateInfo::builder().viewports(&viewports).scissors(&scissors);
    let raster = vk::PipelineRasterizationStateCreateInfo::builder().polygon_mode(vk::PolygonMode::FILL).cull_mode(vk::CullModeFlags::NONE).line_width(1.0);
    let samples = vk::PipelineMultisampleStateCreateInfo::builder().rasterization_samples(vk::SampleCountFlags::TYPE_1);
    let blend_attachments = [vk::PipelineColorBlendAttachmentState::builder().color_write_mask(vk::ColorComponentFlags::RGBA).build()];
    let blending = vk::PipelineColorBlendStateCreateInfo::builder().attachments(&blend_attachments);
    let info = vk::GraphicsPipelineCreateInfo::builder().stages(&stages).vertex_input_state(&vertex)
        .input_assembly_state(&assembly).viewport_state(&viewport).rasterization_state(&raster)
        .multisample_state(&samples).color_blend_state(&blending).layout(layout).render_pass(pass).build();
    let pipeline_result = device.create_graphics_pipelines(vk::PipelineCache::null(), &[info], None);
    device.destroy_shader_module(vs, None); device.destroy_shader_module(ps, None);
    let pipeline = pipeline_result.map_err(|(_, e)| e)?[0];
    let mut frames = Vec::new(); let mut finished = Vec::new();
    for &view in &views {
        frames.push(device.create_framebuffer(&vk::FramebufferCreateInfo::builder().render_pass(pass).attachments(&[view])
            .width(extent.width).height(extent.height).layers(1), None)?);
        finished.push(device.create_semaphore(&vk::SemaphoreCreateInfo::default(), None)?);
    }
    Ok(SwapResources { swap, extent, views, pass, pipeline, frames, finished })
}
unsafe fn run() -> Result<()> {
    let smoke = std::env::args().any(|a| a == "--smoke-test");
    let instance_handle = HINSTANCE(GetModuleHandleW(None)?.0);
    let name = w!("RustVulkanTriangle");
    let wc = WNDCLASSW { lpfnWndProc: Some(window_proc), hInstance: instance_handle, lpszClassName: name,
        hCursor: LoadCursorW(None, IDC_ARROW)?, ..Default::default() };
    if RegisterClassW(&wc) == 0 { return Err(windows::core::Error::from_win32().into()); }
    let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    let mut rect = RECT { left: 0, top: 0, right: 800, bottom: 600 }; AdjustWindowRect(&mut rect, style, false)?;
    let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), name, w!("Rust Vulkan Triangle"), style, CW_USEDEFAULT, CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top, None, None, instance_handle, None);
    if hwnd.0 == 0 { return Err(windows::core::Error::from_win32().into()); }
    let _window = Window(hwnd);
    let entry = Entry::load()?;
    let extensions = [Surface::name().as_ptr(), Win32Surface::name().as_ptr()];
    let instance = entry.create_instance(&vk::InstanceCreateInfo::builder().enabled_extension_names(&extensions), None)?;
    let surface_api = Surface::new(&entry, &instance);
    let surface = Win32Surface::new(&entry, &instance).create_win32_surface(&vk::Win32SurfaceCreateInfoKHR::builder()
        .hinstance(instance_handle.0 as *const std::ffi::c_void).hwnd(hwnd.0 as *const std::ffi::c_void), None)?;
    let mut selected = None;
    for physical in instance.enumerate_physical_devices()? {
        for (i, family) in instance.get_physical_device_queue_family_properties(physical).iter().enumerate() {
            if family.queue_flags.contains(vk::QueueFlags::GRAPHICS) && surface_api.get_physical_device_surface_support(physical, i as u32, surface)? {
                selected = Some((physical, i as u32)); break;
            }
        }
        if selected.is_some() { break; }
    }
    let (physical, family) = selected.ok_or("No Vulkan graphics/presentation device")?;
    let priorities = [1.0];
    let queues = [vk::DeviceQueueCreateInfo::builder().queue_family_index(family).queue_priorities(&priorities).build()];
    let device_extensions = [Swapchain::name().as_ptr()];
    let device = instance.create_device(physical, &vk::DeviceCreateInfo::builder().queue_create_infos(&queues).enabled_extension_names(&device_extensions), None)?;
    let queue = device.get_device_queue(family, 0); let swap_api = Swapchain::new(&instance, &device);
    let layout = device.create_pipeline_layout(&vk::PipelineLayoutCreateInfo::default(), None)?;
    let pool = device.create_command_pool(&vk::CommandPoolCreateInfo::builder().queue_family_index(family), None)?;
    let command = device.allocate_command_buffers(&vk::CommandBufferAllocateInfo::builder().command_pool(pool)
        .level(vk::CommandBufferLevel::PRIMARY).command_buffer_count(1))?[0];
    let acquired = device.create_semaphore(&vk::SemaphoreCreateInfo::default(), None)?;
    let mut r = create_swap(&device, physical, &surface_api, surface, &swap_api, layout)?;
    ShowWindow(hwnd, SW_SHOW);
    let mut frames = 0;
    let rendering = (|| -> Result<()> {
        loop {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT { return Ok(()); }
                TranslateMessage(&msg); DispatchMessageW(&msg);
            }
            if IsIconic(hwnd).as_bool() { Sleep(16); continue; }
            let (index, acquire_suboptimal) = match swap_api.acquire_next_image(r.swap, u64::MAX, acquired, vk::Fence::null()) {
                Ok(value) => value,
                Err(vk::Result::ERROR_OUT_OF_DATE_KHR) => {
                    device.device_wait_idle()?; destroy_swap(&device, &swap_api, &r);
                    r = create_swap(&device, physical, &surface_api, surface, &swap_api, layout)?; continue;
                },
                Err(e) => return Err(e.into()),
            };
            device.reset_command_pool(pool, vk::CommandPoolResetFlags::empty())?;
            device.begin_command_buffer(command, &vk::CommandBufferBeginInfo::default())?;
            let clears = [vk::ClearValue { color: vk::ClearColorValue { float32: [0.08, 0.10, 0.14, 1.0] } }];
            device.cmd_begin_render_pass(command, &vk::RenderPassBeginInfo::builder().render_pass(r.pass)
                .framebuffer(r.frames[index as usize]).render_area(vk::Rect2D { offset: vk::Offset2D::default(), extent: r.extent })
                .clear_values(&clears), vk::SubpassContents::INLINE);
            device.cmd_bind_pipeline(command, vk::PipelineBindPoint::GRAPHICS, r.pipeline);
            device.cmd_draw(command, 3, 1, 0, 0); device.cmd_end_render_pass(command); device.end_command_buffer(command)?;
            let waits = [acquired]; let signals = [r.finished[index as usize]]; let stages = [vk::PipelineStageFlags::COLOR_ATTACHMENT_OUTPUT];
            let commands = [command];
            device.queue_submit(queue, &[vk::SubmitInfo::builder().wait_semaphores(&waits).wait_dst_stage_mask(&stages)
                .command_buffers(&commands).signal_semaphores(&signals).build()], vk::Fence::null())?;
            let swaps = [r.swap]; let indices = [index];
            let present = swap_api.queue_present(queue, &vk::PresentInfoKHR::builder().wait_semaphores(&signals).swapchains(&swaps).image_indices(&indices));
            device.queue_wait_idle(queue)?;
            let recreate = match present { Ok(suboptimal) => suboptimal || acquire_suboptimal,
                Err(vk::Result::ERROR_OUT_OF_DATE_KHR) => true, Err(e) => return Err(e.into()) };
            if recreate { device.device_wait_idle()?; destroy_swap(&device, &swap_api, &r);
                r = create_swap(&device, physical, &surface_api, surface, &swap_api, layout)?; }
            frames += 1; if smoke && frames >= 60 { return Ok(()); }
        }
    })();
    let idle = device.device_wait_idle();
    if idle.is_ok() { destroy_swap(&device, &swap_api, &r); }
    device.destroy_semaphore(acquired, None); device.destroy_command_pool(pool, None); device.destroy_pipeline_layout(layout, None);
    device.destroy_device(None); surface_api.destroy_surface(surface, None); instance.destroy_instance(None);
    rendering?; idle?; Ok(())
}
fn main() {
    if let Err(error) = unsafe { run() } {
        if !std::env::args().any(|a| a == "--smoke-test") {
            let text: Vec<u16> = format!("{error}").encode_utf16().chain(Some(0)).collect();
            unsafe { MessageBoxW(None, windows::core::PCWSTR(text.as_ptr()), w!("Vulkan failed"), MB_OK | MB_ICONERROR); }
        }
        std::process::exit(1);
    }
}
