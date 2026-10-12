#define UNICODE
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace {
void Check(VkResult result) {
    if (result != VK_SUCCESS) {
        char message[80]; std::snprintf(message, sizeof(message), "Vulkan failed: VkResult %d", result);
        throw std::runtime_error(message);
    }
}
LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE || msg == WM_DESTROY || (msg == WM_KEYDOWN && wp == VK_ESCAPE)) {
        PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
struct App {
    HWND window = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t family = 0;
    VkSwapchainKHR swap = VK_NULL_HANDLE;
    VkExtent2D extent = {};
    VkRenderPass pass = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkSemaphore acquired = VK_NULL_HANDLE;
    std::vector<VkImageView> views;
    std::vector<VkFramebuffer> frames;
    std::vector<VkSemaphore> finished;
    void DestroySwap() {
        for (auto s : finished) vkDestroySemaphore(device, s, nullptr); finished.clear();
        for (auto f : frames) vkDestroyFramebuffer(device, f, nullptr); frames.clear();
        if (pipeline) vkDestroyPipeline(device, pipeline, nullptr); pipeline = VK_NULL_HANDLE;
        if (pass) vkDestroyRenderPass(device, pass, nullptr); pass = VK_NULL_HANDLE;
        for (auto v : views) vkDestroyImageView(device, v, nullptr); views.clear();
        if (swap) vkDestroySwapchainKHR(device, swap, nullptr); swap = VK_NULL_HANDLE;
    }
    ~App() {
        if (device) {
            vkDeviceWaitIdle(device); DestroySwap();
            if (acquired) vkDestroySemaphore(device, acquired, nullptr);
            if (pool) vkDestroyCommandPool(device, pool, nullptr);
            if (layout) vkDestroyPipelineLayout(device, layout, nullptr);
            vkDestroyDevice(device, nullptr);
        }
        if (surface) vkDestroySurfaceKHR(instance, surface, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
        if (window) DestroyWindow(window);
    }
};
VkShaderModule Shader(App& app, const char* path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Missing SPIR-V shader; run from tiny via its batch launcher.");
    const auto size = static_cast<size_t>(file.tellg());
    if (!size || size % 4) throw std::runtime_error("Invalid SPIR-V shader size.");
    std::vector<uint32_t> bytes(size / 4); file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(bytes.data()), size)) throw std::runtime_error("Shader read failed.");
    VkShaderModuleCreateInfo info = {}; info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = size; info.pCode = bytes.data(); VkShaderModule module;
    Check(vkCreateShaderModule(app.device, &info, nullptr, &module)); return module;
}
void CreateSwap(App& app) {
    VkSurfaceCapabilitiesKHR caps; Check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(app.physical, app.surface, &caps));
    uint32_t count = 0; Check(vkGetPhysicalDeviceSurfaceFormatsKHR(app.physical, app.surface, &count, nullptr));
    std::vector<VkSurfaceFormatKHR> formats(count); Check(vkGetPhysicalDeviceSurfaceFormatsKHR(app.physical, app.surface, &count, formats.data()));
    if (formats.empty()) throw std::runtime_error("No Vulkan surface formats.");
    auto format = formats[0];
    for (auto candidate : formats) if (candidate.format == VK_FORMAT_B8G8R8A8_UNORM && candidate.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) format = candidate;
    if (format.format == VK_FORMAT_UNDEFINED) format.format = VK_FORMAT_B8G8R8A8_UNORM;
    app.extent = caps.currentExtent;
    if (app.extent.width == UINT32_MAX) {
        RECT rect; GetClientRect(app.window, &rect);
        app.extent = {std::clamp<uint32_t>(rect.right, caps.minImageExtent.width, caps.maxImageExtent.width),
            std::clamp<uint32_t>(rect.bottom, caps.minImageExtent.height, caps.maxImageExtent.height)};
    }
    uint32_t image_count = std::max(2u, caps.minImageCount);
    if (caps.maxImageCount) image_count = std::min(image_count, caps.maxImageCount);
    VkSwapchainCreateInfoKHR info = {}; info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    info.surface = app.surface; info.minImageCount = image_count; info.imageFormat = format.format;
    info.imageColorSpace = format.colorSpace; info.imageExtent = app.extent; info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT; info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = caps.currentTransform;
    for (uint32_t bit = 1; bit <= VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR; bit <<= 1)
        if (caps.supportedCompositeAlpha & bit) { info.compositeAlpha = static_cast<VkCompositeAlphaFlagBitsKHR>(bit); break; }
    info.presentMode = VK_PRESENT_MODE_FIFO_KHR; info.clipped = VK_TRUE;
    Check(vkCreateSwapchainKHR(app.device, &info, nullptr, &app.swap));
    Check(vkGetSwapchainImagesKHR(app.device, app.swap, &count, nullptr));
    std::vector<VkImage> images(count); Check(vkGetSwapchainImagesKHR(app.device, app.swap, &count, images.data()));
    for (auto image : images) {
        VkImageViewCreateInfo view = {}; view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = image; view.viewType = VK_IMAGE_VIEW_TYPE_2D; view.format = format.format;
        view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}; VkImageView handle;
        Check(vkCreateImageView(app.device, &view, nullptr, &handle)); app.views.push_back(handle);
    }
    VkAttachmentDescription attachment = {}; attachment.format = format.format; attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {}; subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &ref;
    VkSubpassDependency dependency = {}; dependency.srcSubpass = VK_SUBPASS_EXTERNAL; dependency.dstSubpass = 0;
    dependency.srcStageMask = dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo render = {}; render.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    render.attachmentCount = 1; render.pAttachments = &attachment; render.subpassCount = 1; render.pSubpasses = &subpass;
    render.dependencyCount = 1; render.pDependencies = &dependency;
    Check(vkCreateRenderPass(app.device, &render, nullptr, &app.pass));
    const auto vs = Shader(app, "hello-vulkan/src/triangle.vert.spv");
    VkShaderModule ps = VK_NULL_HANDLE;
    try { ps = Shader(app, "hello-vulkan/src/triangle.frag.spv"); } catch (...) { vkDestroyShaderModule(app.device, vs, nullptr); throw; }
    VkPipelineShaderStageCreateInfo stages[2] = {};
    for (auto& stage : stages) { stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; stage.pName = "main"; }
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vs; stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = ps;
    VkPipelineVertexInputStateCreateInfo vertex = {}; vertex.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    VkPipelineInputAssemblyStateCreateInfo assembly = {}; assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO; assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport = {0, 0, static_cast<float>(app.extent.width), static_cast<float>(app.extent.height), 0, 1}; VkRect2D scissor = {{0, 0}, app.extent};
    VkPipelineViewportStateCreateInfo viewport_state = {}; viewport_state.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = viewport_state.scissorCount = 1; viewport_state.pViewports = &viewport; viewport_state.pScissors = &scissor;
    VkPipelineRasterizationStateCreateInfo raster = {}; raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo samples = {}; samples.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO; samples.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blend = {}; blend.colorWriteMask = 15;
    VkPipelineColorBlendStateCreateInfo blending = {}; blending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO; blending.attachmentCount = 1; blending.pAttachments = &blend;
    VkGraphicsPipelineCreateInfo pipeline = {}; pipeline.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline.stageCount = 2; pipeline.pStages = stages; pipeline.pVertexInputState = &vertex; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport_state; pipeline.pRasterizationState = &raster; pipeline.pMultisampleState = &samples; pipeline.pColorBlendState = &blending;
    pipeline.layout = app.layout; pipeline.renderPass = app.pass;
    const auto result = vkCreateGraphicsPipelines(app.device, VK_NULL_HANDLE, 1, &pipeline, nullptr, &app.pipeline);
    vkDestroyShaderModule(app.device, vs, nullptr); vkDestroyShaderModule(app.device, ps, nullptr); Check(result);
    for (auto view : app.views) {
        VkFramebufferCreateInfo frame = {}; frame.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        frame.renderPass = app.pass; frame.attachmentCount = 1; frame.pAttachments = &view;
        frame.width = app.extent.width; frame.height = app.extent.height; frame.layers = 1;
        VkFramebuffer framebuffer; Check(vkCreateFramebuffer(app.device, &frame, nullptr, &framebuffer)); app.frames.push_back(framebuffer);
        VkSemaphoreCreateInfo sem = {}; sem.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        VkSemaphore semaphore; Check(vkCreateSemaphore(app.device, &sem, nullptr, &semaphore)); app.finished.push_back(semaphore);
    }
}
void Initialize(App& app) {
    const char* extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo info = {}; info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; info.enabledExtensionCount = 2; info.ppEnabledExtensionNames = extensions;
    Check(vkCreateInstance(&info, nullptr, &app.instance));
    VkWin32SurfaceCreateInfoKHR win = {}; win.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR; win.hinstance = GetModuleHandleW(nullptr); win.hwnd = app.window;
    Check(vkCreateWin32SurfaceKHR(app.instance, &win, nullptr, &app.surface));
    uint32_t count = 0; Check(vkEnumeratePhysicalDevices(app.instance, &count, nullptr));
    std::vector<VkPhysicalDevice> physical(count); Check(vkEnumeratePhysicalDevices(app.instance, &count, physical.data()));
    for (auto candidate : physical) {
        uint32_t n = 0; vkGetPhysicalDeviceQueueFamilyProperties(candidate, &n, nullptr); std::vector<VkQueueFamilyProperties> families(n); vkGetPhysicalDeviceQueueFamilyProperties(candidate, &n, families.data());
        for (uint32_t i = 0; i < n; ++i) {
            VkBool32 supported = 0; Check(vkGetPhysicalDeviceSurfaceSupportKHR(candidate, i, app.surface, &supported));
            if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && supported) { app.physical = candidate; app.family = i; break; }
        }
        if (app.physical) break;
    }
    if (!app.physical) throw std::runtime_error("No Vulkan graphics/presentation device.");
    const float priority = 1; VkDeviceQueueCreateInfo q = {}; q.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO; q.queueFamilyIndex = app.family; q.queueCount = 1; q.pQueuePriorities = &priority;
    const char* extension = VK_KHR_SWAPCHAIN_EXTENSION_NAME; VkDeviceCreateInfo device = {}; device.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device.queueCreateInfoCount = 1; device.pQueueCreateInfos = &q; device.enabledExtensionCount = 1; device.ppEnabledExtensionNames = &extension;
    Check(vkCreateDevice(app.physical, &device, nullptr, &app.device)); vkGetDeviceQueue(app.device, app.family, 0, &app.queue);
    VkPipelineLayoutCreateInfo layout = {}; layout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO; Check(vkCreatePipelineLayout(app.device, &layout, nullptr, &app.layout));
    VkCommandPoolCreateInfo pool = {}; pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO; pool.queueFamilyIndex = app.family;
    Check(vkCreateCommandPool(app.device, &pool, nullptr, &app.pool));
    VkCommandBufferAllocateInfo allocate = {}; allocate.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO; allocate.commandPool = app.pool; allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; allocate.commandBufferCount = 1;
    Check(vkAllocateCommandBuffers(app.device, &allocate, &app.command));
    VkSemaphoreCreateInfo sem = {}; sem.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO; Check(vkCreateSemaphore(app.device, &sem, nullptr, &app.acquired)); CreateSwap(app);
}
bool Draw(App& app) {
    uint32_t index; const auto acquired = vkAcquireNextImageKHR(app.device, app.swap, UINT64_MAX, app.acquired, VK_NULL_HANDLE, &index);
    if (acquired == VK_ERROR_OUT_OF_DATE_KHR) { Check(vkDeviceWaitIdle(app.device)); app.DestroySwap(); CreateSwap(app); return false; }
    if (acquired != VK_SUBOPTIMAL_KHR) Check(acquired);
    Check(vkResetCommandPool(app.device, app.pool, 0));
    VkCommandBufferBeginInfo begin = {}; begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO; Check(vkBeginCommandBuffer(app.command, &begin));
    VkClearValue clear = {}; clear.color.float32[0] = 0.08f; clear.color.float32[1] = 0.10f; clear.color.float32[2] = 0.14f; clear.color.float32[3] = 1;
    VkRenderPassBeginInfo render = {}; render.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO; render.renderPass = app.pass; render.framebuffer = app.frames[index]; render.renderArea.extent = app.extent; render.clearValueCount = 1; render.pClearValues = &clear;
    vkCmdBeginRenderPass(app.command, &render, VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(app.command, VK_PIPELINE_BIND_POINT_GRAPHICS, app.pipeline); vkCmdDraw(app.command, 3, 1, 0, 0); vkCmdEndRenderPass(app.command); Check(vkEndCommandBuffer(app.command));
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {}; submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO; submit.waitSemaphoreCount = 1; submit.pWaitSemaphores = &app.acquired; submit.pWaitDstStageMask = &stage; submit.commandBufferCount = 1; submit.pCommandBuffers = &app.command; submit.signalSemaphoreCount = 1; submit.pSignalSemaphores = &app.finished[index];
    Check(vkQueueSubmit(app.queue, 1, &submit, VK_NULL_HANDLE));
    VkPresentInfoKHR present = {}; present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR; present.waitSemaphoreCount = 1; present.pWaitSemaphores = &app.finished[index]; present.swapchainCount = 1; present.pSwapchains = &app.swap; present.pImageIndices = &index;
    const auto result = vkQueuePresentKHR(app.queue, &present); Check(vkQueueWaitIdle(app.queue));
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR || acquired == VK_SUBOPTIMAL_KHR) { Check(vkDeviceWaitIdle(app.device)); app.DestroySwap(); CreateSwap(app); }
    else Check(result);
    return true;
}
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR args, int show) {
    const bool smoke = wcsstr(args, L"--smoke-test") != nullptr;
    try {
        App app; WNDCLASSW wc = {}; wc.lpfnWndProc = WindowProc; wc.hInstance = instance; wc.lpszClassName = L"CppVulkanTriangle"; wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        if (!RegisterClassW(&wc)) throw std::runtime_error("Window class failed.");
        const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX; RECT rect = {0, 0, 800, 600}; AdjustWindowRect(&rect, style, FALSE);
        app.window = CreateWindowExW(0, wc.lpszClassName, L"C++ Vulkan Triangle", style, CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, instance, nullptr);
        if (!app.window) throw std::runtime_error("Window creation failed.");
        Initialize(app); ShowWindow(app.window, show); unsigned frames = 0;
        while (true) {
            MSG msg; while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { if (msg.message == WM_QUIT) return 0; TranslateMessage(&msg); DispatchMessageW(&msg); }
            if (IsIconic(app.window)) { Sleep(16); continue; }
            if (Draw(app)) ++frames;
            if (smoke && frames >= 60) return 0;
        }
    } catch (const std::exception& error) {
        if (!smoke) MessageBoxA(nullptr, error.what(), "Vulkan failed", MB_OK | MB_ICONERROR);
        OutputDebugStringA(error.what()); return 1;
    }
}
