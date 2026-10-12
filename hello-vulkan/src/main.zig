const std = @import("std");
const c = @import("win");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const vs_bytes align(4) = @embedFile("triangle.vert.spv").*;
const ps_bytes align(4) = @embedFile("triangle.frag.spv").*;
fn check(result: c.VkResult) !void { if (result != c.VK_SUCCESS) return error.VulkanFailure; }
fn windowProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CLOSE, c.WM_DESTROY => { c.PostQuitMessage(0); return 0; },
        c.WM_KEYDOWN => if (wp == c.VK_ESCAPE) { c.PostQuitMessage(0); return 0; },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
const App = struct {
    allocator: std.mem.Allocator,
    hwnd: c.HWND = null,
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    family: u32 = 0,
    swap: c.VkSwapchainKHR = null,
    extent: c.VkExtent2D = .{ .width = 800, .height = 600 },
    pass: c.VkRenderPass = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    pool: c.VkCommandPool = null,
    command: c.VkCommandBuffer = null,
    acquired: c.VkSemaphore = null,
    views: []c.VkImageView = &.{},
    frames: []c.VkFramebuffer = &.{},
    finished: []c.VkSemaphore = &.{},
    fn destroySwap(a: *App) void {
        for (a.finished) |s| if (s != null) { c.vkDestroySemaphore(a.device, s, null); };
        for (a.frames) |f| if (f != null) { c.vkDestroyFramebuffer(a.device, f, null); };
        if (a.pipeline != null) c.vkDestroyPipeline(a.device, a.pipeline, null);
        if (a.pass != null) c.vkDestroyRenderPass(a.device, a.pass, null);
        for (a.views) |v| if (v != null) { c.vkDestroyImageView(a.device, v, null); };
        if (a.swap != null) c.vkDestroySwapchainKHR(a.device, a.swap, null);
        a.allocator.free(a.finished); a.allocator.free(a.frames); a.allocator.free(a.views);
        a.finished = &.{}; a.frames = &.{}; a.views = &.{};
        a.pipeline = null; a.pass = null; a.swap = null;
    }
    fn deinit(a: *App) void {
        if (a.device != null) {
            _ = c.vkDeviceWaitIdle(a.device); a.destroySwap();
            if (a.acquired != null) c.vkDestroySemaphore(a.device, a.acquired, null);
            if (a.pool != null) c.vkDestroyCommandPool(a.device, a.pool, null);
            if (a.layout != null) c.vkDestroyPipelineLayout(a.device, a.layout, null);
            c.vkDestroyDevice(a.device, null);
        }
        if (a.surface != null) c.vkDestroySurfaceKHR(a.instance, a.surface, null);
        if (a.instance != null) c.vkDestroyInstance(a.instance, null);
        if (a.hwnd != null) _ = c.DestroyWindow(a.hwnd);
    }
    fn shader(a: *App, bytes: []align(4) const u8) !c.VkShaderModule {
        var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO; info.codeSize = bytes.len; info.pCode = @ptrCast(bytes.ptr);
        var module: c.VkShaderModule = null;
        try check(c.vkCreateShaderModule(a.device, &info, null, &module)); return module;
    }
    fn createSwap(a: *App) !void {
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(a.physical, a.surface, &caps));
        var count: u32 = 0;
        try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(a.physical, a.surface, &count, null));
        if (count == 0) return error.NoSurfaceFormats;
        const formats = try a.allocator.alloc(c.VkSurfaceFormatKHR, count); defer a.allocator.free(formats);
        try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(a.physical, a.surface, &count, formats.ptr));
        var format = formats[0];
        for (formats) |f| if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) { format = f; };
        if (format.format == c.VK_FORMAT_UNDEFINED) format.format = c.VK_FORMAT_B8G8R8A8_UNORM;
        a.extent = caps.currentExtent;
        if (a.extent.width == std.math.maxInt(u32)) a.extent = .{
            .width = std.math.clamp(@as(u32, 800), caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(@as(u32, 600), caps.minImageExtent.height, caps.maxImageExtent.height),
        };
        var image_count = @max(@as(u32, 2), caps.minImageCount);
        if (caps.maxImageCount != 0) image_count = @min(image_count, caps.maxImageCount);
        var info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR; info.surface = a.surface;
        info.minImageCount = image_count; info.imageFormat = format.format; info.imageColorSpace = format.colorSpace;
        info.imageExtent = a.extent; info.imageArrayLayers = 1; info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE; info.preTransform = caps.currentTransform;
        var bit: u32 = 1;
        while (bit <= c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) : (bit <<= 1) {
            if (caps.supportedCompositeAlpha & bit != 0) { info.compositeAlpha = bit; break; }
        }
        info.presentMode = c.VK_PRESENT_MODE_FIFO_KHR; info.clipped = c.VK_TRUE;
        try check(c.vkCreateSwapchainKHR(a.device, &info, null, &a.swap));
        try check(c.vkGetSwapchainImagesKHR(a.device, a.swap, &count, null));
        const images = try a.allocator.alloc(c.VkImage, count); defer a.allocator.free(images);
        try check(c.vkGetSwapchainImagesKHR(a.device, a.swap, &count, images.ptr));
        a.views = try a.allocator.alloc(c.VkImageView, count); @memset(a.views, null);
        a.frames = try a.allocator.alloc(c.VkFramebuffer, count); @memset(a.frames, null);
        a.finished = try a.allocator.alloc(c.VkSemaphore, count); @memset(a.finished, null);
        for (images, a.views) |image, *view| {
            var v = std.mem.zeroes(c.VkImageViewCreateInfo); v.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            v.image = image; v.viewType = c.VK_IMAGE_VIEW_TYPE_2D; v.format = format.format;
            v.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try check(c.vkCreateImageView(a.device, &v, null, view));
        }
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = format.format; attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        const ref: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var subpass = std.mem.zeroes(c.VkSubpassDescription); subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &ref;
        var dependency = std.mem.zeroes(c.VkSubpassDependency); dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT; dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        var render = std.mem.zeroes(c.VkRenderPassCreateInfo); render.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render.attachmentCount = 1; render.pAttachments = &attachment; render.subpassCount = 1; render.pSubpasses = &subpass;
        render.dependencyCount = 1; render.pDependencies = &dependency;
        try check(c.vkCreateRenderPass(a.device, &render, null, &a.pass));
        const vs = try a.shader(&vs_bytes); defer c.vkDestroyShaderModule(a.device, vs, null);
        const ps = try a.shader(&ps_bytes); defer c.vkDestroyShaderModule(a.device, ps, null);
        var stages = [_]c.VkPipelineShaderStageCreateInfo{std.mem.zeroes(c.VkPipelineShaderStageCreateInfo)} ** 2;
        for (&stages) |*s| { s.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; s.pName = "main"; }
        stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vs;
        stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = ps;
        var vertex = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo); vertex.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        var assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo); assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO; assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        const viewport: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(a.extent.width), .height = @floatFromInt(a.extent.height), .minDepth = 0, .maxDepth = 1 };
        const scissor: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = a.extent };
        var vp = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo); vp.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1; vp.pViewports = &viewport; vp.scissorCount = 1; vp.pScissors = &scissor;
        var raster = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo); raster.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = c.VK_POLYGON_MODE_FILL; raster.cullMode = c.VK_CULL_MODE_NONE; raster.lineWidth = 1;
        var samples = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo); samples.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO; samples.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var blend = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState); blend.colorWriteMask = 15;
        var blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo); blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO; blending.attachmentCount = 1; blending.pAttachments = &blend;
        var pipeline = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo); pipeline.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline.stageCount = 2; pipeline.pStages = &stages; pipeline.pVertexInputState = &vertex; pipeline.pInputAssemblyState = &assembly;
        pipeline.pViewportState = &vp; pipeline.pRasterizationState = &raster; pipeline.pMultisampleState = &samples; pipeline.pColorBlendState = &blending;
        pipeline.layout = a.layout; pipeline.renderPass = a.pass;
        try check(c.vkCreateGraphicsPipelines(a.device, null, 1, &pipeline, null, &a.pipeline));
        for (a.views, a.frames, a.finished) |*view, *frame, *finished| {
            var f = std.mem.zeroes(c.VkFramebufferCreateInfo); f.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            f.renderPass = a.pass; f.attachmentCount = 1; f.pAttachments = view; f.width = a.extent.width; f.height = a.extent.height; f.layers = 1;
            try check(c.vkCreateFramebuffer(a.device, &f, null, frame));
            var sem = std.mem.zeroes(c.VkSemaphoreCreateInfo); sem.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            try check(c.vkCreateSemaphore(a.device, &sem, null, finished));
        }
    }
    fn initialize(a: *App) !void {
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
        var info = std.mem.zeroes(c.VkInstanceCreateInfo); info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        info.enabledExtensionCount = 2; info.ppEnabledExtensionNames = @ptrCast(&extensions);
        try check(c.vkCreateInstance(&info, null, &a.instance));
        var win = std.mem.zeroes(c.VkWin32SurfaceCreateInfoKHR); win.sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
        win.hinstance = c.GetModuleHandleW(null); win.hwnd = a.hwnd;
        try check(c.vkCreateWin32SurfaceKHR(a.instance, &win, null, &a.surface));
        var count: u32 = 0; try check(c.vkEnumeratePhysicalDevices(a.instance, &count, null));
        const physical = try a.allocator.alloc(c.VkPhysicalDevice, count); defer a.allocator.free(physical);
        try check(c.vkEnumeratePhysicalDevices(a.instance, &count, physical.ptr));
        for (physical) |candidate| {
            var n: u32 = 0; c.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &n, null);
            const families = try a.allocator.alloc(c.VkQueueFamilyProperties, n); defer a.allocator.free(families);
            c.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &n, families.ptr);
            for (families, 0..) |family, i| {
                var supported: c.VkBool32 = 0;
                try check(c.vkGetPhysicalDeviceSurfaceSupportKHR(candidate, @intCast(i), a.surface, &supported));
                if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0 and supported != 0) { a.physical = candidate; a.family = @intCast(i); break; }
            }
            if (a.physical != null) break;
        }
        if (a.physical == null) return error.NoGraphicsDevice;
        const priority: f32 = 1;
        var q = std.mem.zeroes(c.VkDeviceQueueCreateInfo); q.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        q.queueFamilyIndex = a.family; q.queueCount = 1; q.pQueuePriorities = &priority;
        const extension = [_][*:0]const u8{"VK_KHR_swapchain"};
        var d = std.mem.zeroes(c.VkDeviceCreateInfo); d.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        d.queueCreateInfoCount = 1; d.pQueueCreateInfos = &q; d.enabledExtensionCount = 1; d.ppEnabledExtensionNames = @ptrCast(&extension);
        try check(c.vkCreateDevice(a.physical, &d, null, &a.device)); c.vkGetDeviceQueue(a.device, a.family, 0, &a.queue);
        var layout = std.mem.zeroes(c.VkPipelineLayoutCreateInfo); layout.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        try check(c.vkCreatePipelineLayout(a.device, &layout, null, &a.layout));
        var pool = std.mem.zeroes(c.VkCommandPoolCreateInfo); pool.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO; pool.queueFamilyIndex = a.family;
        try check(c.vkCreateCommandPool(a.device, &pool, null, &a.pool));
        var allocate = std.mem.zeroes(c.VkCommandBufferAllocateInfo); allocate.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocate.commandPool = a.pool; allocate.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY; allocate.commandBufferCount = 1;
        try check(c.vkAllocateCommandBuffers(a.device, &allocate, &a.command));
        var sem = std.mem.zeroes(c.VkSemaphoreCreateInfo); sem.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        try check(c.vkCreateSemaphore(a.device, &sem, null, &a.acquired)); try a.createSwap();
    }
    fn recreate(a: *App) !void { try check(c.vkDeviceWaitIdle(a.device)); a.destroySwap(); try a.createSwap(); }
    fn draw(a: *App) !bool {
        var index: u32 = 0;
        const acquired = c.vkAcquireNextImageKHR(a.device, a.swap, std.math.maxInt(u64), a.acquired, null, &index);
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) { try a.recreate(); return false; }
        if (acquired != c.VK_SUBOPTIMAL_KHR) try check(acquired);
        try check(c.vkResetCommandPool(a.device, a.pool, 0));
        var begin = std.mem.zeroes(c.VkCommandBufferBeginInfo); begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try check(c.vkBeginCommandBuffer(a.command, &begin));
        var clear = std.mem.zeroes(c.VkClearValue); clear.color.float32 = .{ 0.08, 0.10, 0.14, 1 };
        var render = std.mem.zeroes(c.VkRenderPassBeginInfo); render.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render.renderPass = a.pass; render.framebuffer = a.frames[index]; render.renderArea.extent = a.extent;
        render.clearValueCount = 1; render.pClearValues = &clear;
        c.vkCmdBeginRenderPass(a.command, &render, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(a.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, a.pipeline);
        c.vkCmdDraw(a.command, 3, 1, 0, 0); c.vkCmdEndRenderPass(a.command); try check(c.vkEndCommandBuffer(a.command));
        const stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var submit = std.mem.zeroes(c.VkSubmitInfo); submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1; submit.pWaitSemaphores = &a.acquired; submit.pWaitDstStageMask = &stage;
        submit.commandBufferCount = 1; submit.pCommandBuffers = &a.command; submit.signalSemaphoreCount = 1; submit.pSignalSemaphores = &a.finished[index];
        try check(c.vkQueueSubmit(a.queue, 1, &submit, null));
        var present = std.mem.zeroes(c.VkPresentInfoKHR); present.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.waitSemaphoreCount = 1; present.pWaitSemaphores = &a.finished[index];
        present.swapchainCount = 1; present.pSwapchains = &a.swap; present.pImageIndices = &index;
        const result = c.vkQueuePresentKHR(a.queue, &present); try check(c.vkQueueWaitIdle(a.queue));
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or acquired == c.VK_SUBOPTIMAL_KHR) try a.recreate() else try check(result);
        return true;
    }
};
pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator); defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator()); var smoke = false;
    for (args[1..]) |arg| { if (std.mem.eql(u8, arg, "--smoke-test")) smoke = true else return error.UnknownArgument; }
    var app: App = .{ .allocator = std.heap.page_allocator }; defer app.deinit();
    const instance = c.GetModuleHandleW(null); const name = wide("ZigVulkanTriangle");
    var wc = std.mem.zeroes(c.WNDCLASSW); wc.lpfnWndProc = windowProc; wc.hInstance = instance; wc.lpszClassName = name;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&wc) == 0) return error.WindowClassFailed;
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    if (c.AdjustWindowRect(&rect, style, c.FALSE) == 0) return error.WindowRectFailed;
    app.hwnd = c.CreateWindowExW(0, name, wide("Zig Vulkan Triangle"), style, c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null) orelse return error.WindowCreationFailed;
    try app.initialize(); _ = c.ShowWindow(app.hwnd, c.SW_SHOW); var frames: u32 = 0;
    while (true) {
        var msg: c.MSG = undefined;
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) return;
            _ = c.TranslateMessage(&msg); _ = c.DispatchMessageW(&msg);
        }
        if (c.IsIconic(app.hwnd) != 0) { c.Sleep(16); continue; }
        if (try app.draw()) frames += 1;
        if (smoke and frames >= 60) return;
    }
}
