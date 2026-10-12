const std = @import("std");
const c = @import("win");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const width = 800;
const height = 600;
const shader = @embedFile("triangle.hlsl");

fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.log.err("DirectX call failed: HRESULT 0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectXFailure;
    }
}

fn release(object: anytype) void {
    _ = object.lpVtbl.*.Release.?(object);
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_KEYDOWN => if (wp == c.VK_ESCAPE) {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

fn compile(entry: [*:0]const u8, target: [*:0]const u8) !*c.ID3DBlob {
    var blob: ?*c.ID3DBlob = null;
    var diagnostics: ?*c.ID3DBlob = null;
    defer if (diagnostics) |d| release(d);
    const hr = c.D3DCompile(shader.ptr, shader.len, "triangle.hlsl", null, null, entry, target, c.D3DCOMPILE_ENABLE_STRICTNESS, 0, &blob, &diagnostics);
    if (hr < 0) {
        if (diagnostics) |d| {
            const bytes: [*]const u8 = @ptrCast(d.lpVtbl.*.GetBufferPointer.?(d));
            std.log.err("Shader: {s}", .{bytes[0..d.lpVtbl.*.GetBufferSize.?(d)]});
        }
        try check(hr);
    }
    return blob.?;
}

fn bytecode(blob: *c.ID3DBlob) c.D3D12_SHADER_BYTECODE {
    return .{ .pShaderBytecode = blob.lpVtbl.*.GetBufferPointer.?(blob), .BytecodeLength = blob.lpVtbl.*.GetBufferSize.?(blob) };
}

// Wait before reusing the allocator or releasing GPU resources.
fn waitGpu(queue: *c.ID3D12CommandQueue, fence: *c.ID3D12Fence, event: c.HANDLE, value: *u64) !void {
    value.* += 1;
    try check(queue.lpVtbl.*.Signal.?(queue, fence, value.*));
    if (fence.lpVtbl.*.GetCompletedValue.?(fence) < value.*) {
        try check(fence.lpVtbl.*.SetEventOnCompletion.?(fence, value.*, event));
        if (c.WaitForSingleObject(event, c.INFINITE) != c.WAIT_OBJECT_0) return error.FenceWaitFailed;
    }
}

fn transition(resource: *c.ID3D12Resource, before: c.D3D12_RESOURCE_STATES, after: c.D3D12_RESOURCE_STATES) c.D3D12_RESOURCE_BARRIER {
    var barrier = std.mem.zeroes(c.D3D12_RESOURCE_BARRIER);
    barrier.Type = c.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.unnamed_0.Transition = .{
        .pResource = resource,
        .Subresource = c.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        .StateBefore = before,
        .StateAfter = after,
    };
    return barrier;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var frame_limit: ?u32 = null;
    var use_warp = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) frame_limit = 60 else if (std.mem.eql(u8, arg, "--warp")) use_warp = true else return error.UnknownArgument;
    }
    const instance = c.GetModuleHandleW(null);
    const class_name = wide("ZigDx12Triangle");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = class_name;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassExW(&wc) == 0) return error.WindowClassFailed;
    defer _ = c.UnregisterClassW(class_name, instance);
    // A fixed client size keeps this introductory example's swap chain simple.
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
    if (c.AdjustWindowRect(&rect, style, c.FALSE) == 0) return error.WindowRectFailed;
    const hwnd = c.CreateWindowExW(0, class_name, wide("Hello World - Zig + DirectX 12"), style, c.CW_USEDEFAULT, c.CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null) orelse return error.WindowCreationFailed;
    defer if (c.IsWindow(hwnd) != 0) {
        _ = c.DestroyWindow(hwnd);
    };

    var factory: *c.IDXGIFactory4 = undefined;
    try check(c.CreateDXGIFactory2(0, &c.IID_IDXGIFactory4, @ptrCast(&factory)));
    defer release(factory);
    var adapter: ?*c.IDXGIAdapter = null;
    defer if (adapter) |a| release(a);
    if (use_warp) try check(factory.lpVtbl.*.EnumWarpAdapter.?(factory, &c.IID_IDXGIAdapter, @ptrCast(&adapter)));
    var device: *c.ID3D12Device = undefined;
    var hr = c.D3D12CreateDevice(@ptrCast(adapter), c.D3D_FEATURE_LEVEL_11_0, &c.IID_ID3D12Device, @ptrCast(&device));
    if (hr < 0 and !use_warp) {
        std.log.info("Hardware device unavailable; using WARP software rendering", .{});
        try check(factory.lpVtbl.*.EnumWarpAdapter.?(factory, &c.IID_IDXGIAdapter, @ptrCast(&adapter)));
        hr = c.D3D12CreateDevice(@ptrCast(adapter), c.D3D_FEATURE_LEVEL_11_0, &c.IID_ID3D12Device, @ptrCast(&device));
    }
    try check(hr);
    defer release(device);
    var queue: *c.ID3D12CommandQueue = undefined;
    var queue_desc = std.mem.zeroes(c.D3D12_COMMAND_QUEUE_DESC);
    queue_desc.Type = c.D3D12_COMMAND_LIST_TYPE_DIRECT;
    try check(device.lpVtbl.*.CreateCommandQueue.?(device, &queue_desc, &c.IID_ID3D12CommandQueue, @ptrCast(&queue)));
    defer release(queue);

    var swap_desc = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC1);
    swap_desc.Width = width;
    swap_desc.Height = height;
    swap_desc.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = 2;
    swap_desc.SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD;
    var swap1: *c.IDXGISwapChain1 = undefined;
    try check(factory.lpVtbl.*.CreateSwapChainForHwnd.?(factory, @ptrCast(queue), hwnd, &swap_desc, null, null, @ptrCast(&swap1)));
    defer release(swap1);
    var swap: *c.IDXGISwapChain3 = undefined;
    try check(swap1.lpVtbl.*.QueryInterface.?(swap1, &c.IID_IDXGISwapChain3, @ptrCast(&swap)));
    defer release(swap);
    try check(factory.lpVtbl.*.MakeWindowAssociation.?(factory, hwnd, c.DXGI_MWA_NO_ALT_ENTER));

    var heap_desc = std.mem.zeroes(c.D3D12_DESCRIPTOR_HEAP_DESC);
    heap_desc.Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = 2;
    var heap: *c.ID3D12DescriptorHeap = undefined;
    try check(device.lpVtbl.*.CreateDescriptorHeap.?(device, &heap_desc, &c.IID_ID3D12DescriptorHeap, @ptrCast(&heap)));
    defer release(heap);
    var handle: c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
    _ = heap.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap, &handle);
    const stride = device.lpVtbl.*.GetDescriptorHandleIncrementSize.?(device, c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    var buffers: [2]*c.ID3D12Resource = undefined;
    var handles: [2]c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
    var acquired: usize = 0;
    defer for (buffers[0..acquired]) |buffer| release(buffer);
    for (&buffers, &handles, 0..) |*buffer, *rtv, i| {
        try check(swap.lpVtbl.*.GetBuffer.?(swap, @intCast(i), &c.IID_ID3D12Resource, @ptrCast(buffer)));
        acquired += 1;
        rtv.* = .{ .ptr = handle.ptr + i * stride };
        device.lpVtbl.*.CreateRenderTargetView.?(device, buffer.*, null, rtv.*);
    }

    var root_desc = std.mem.zeroes(c.D3D12_ROOT_SIGNATURE_DESC);
    var root_blob: ?*c.ID3DBlob = null;
    var root_errors: ?*c.ID3DBlob = null;
    defer if (root_blob) |blob| release(blob);
    defer if (root_errors) |blob| release(blob);
    try check(c.D3D12SerializeRootSignature(&root_desc, c.D3D_ROOT_SIGNATURE_VERSION_1, &root_blob, &root_errors));
    var root: *c.ID3D12RootSignature = undefined;
    try check(device.lpVtbl.*.CreateRootSignature.?(device, 0, root_blob.?.lpVtbl.*.GetBufferPointer.?(root_blob.?), root_blob.?.lpVtbl.*.GetBufferSize.?(root_blob.?), &c.IID_ID3D12RootSignature, @ptrCast(&root)));
    defer release(root);
    const vs = try compile("VSMain", "vs_5_0");
    defer release(vs);
    const ps = try compile("PSMain", "ps_5_0");
    defer release(ps);
    var pipeline_desc = std.mem.zeroes(c.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    pipeline_desc.pRootSignature = root;
    pipeline_desc.VS = bytecode(vs);
    pipeline_desc.PS = bytecode(ps);
    pipeline_desc.SampleMask = std.math.maxInt(u32);
    pipeline_desc.RasterizerState.FillMode = c.D3D12_FILL_MODE_SOLID;
    pipeline_desc.RasterizerState.CullMode = c.D3D12_CULL_MODE_NONE;
    pipeline_desc.RasterizerState.DepthClipEnable = c.TRUE;
    pipeline_desc.BlendState.RenderTarget[0] = .{
        .BlendEnable = c.FALSE,
        .LogicOpEnable = c.FALSE,
        .SrcBlend = c.D3D12_BLEND_ONE,
        .DestBlend = c.D3D12_BLEND_ZERO,
        .BlendOp = c.D3D12_BLEND_OP_ADD,
        .SrcBlendAlpha = c.D3D12_BLEND_ONE,
        .DestBlendAlpha = c.D3D12_BLEND_ZERO,
        .BlendOpAlpha = c.D3D12_BLEND_OP_ADD,
        .LogicOp = c.D3D12_LOGIC_OP_NOOP,
        .RenderTargetWriteMask = c.D3D12_COLOR_WRITE_ENABLE_ALL,
    };
    pipeline_desc.DepthStencilState.DepthFunc = c.D3D12_COMPARISON_FUNC_ALWAYS;
    pipeline_desc.PrimitiveTopologyType = c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipeline_desc.NumRenderTargets = 1;
    pipeline_desc.RTVFormats[0] = swap_desc.Format;
    pipeline_desc.SampleDesc.Count = 1;
    var pipeline: *c.ID3D12PipelineState = undefined;
    try check(device.lpVtbl.*.CreateGraphicsPipelineState.?(device, &pipeline_desc, &c.IID_ID3D12PipelineState, @ptrCast(&pipeline)));
    defer release(pipeline);
    var allocator: *c.ID3D12CommandAllocator = undefined;
    try check(device.lpVtbl.*.CreateCommandAllocator.?(device, c.D3D12_COMMAND_LIST_TYPE_DIRECT, &c.IID_ID3D12CommandAllocator, @ptrCast(&allocator)));
    defer release(allocator);
    var list: *c.ID3D12GraphicsCommandList = undefined;
    try check(device.lpVtbl.*.CreateCommandList.?(device, 0, c.D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, pipeline, &c.IID_ID3D12GraphicsCommandList, @ptrCast(&list)));
    defer release(list);
    try check(list.lpVtbl.*.Close.?(list));
    var fence: *c.ID3D12Fence = undefined;
    try check(device.lpVtbl.*.CreateFence.?(device, 0, c.D3D12_FENCE_FLAG_NONE, &c.IID_ID3D12Fence, @ptrCast(&fence)));
    defer release(fence);
    const event = c.CreateEventW(null, c.FALSE, c.FALSE, null) orelse return error.EventCreationFailed;
    defer _ = c.CloseHandle(event);
    var fence_value: u64 = 0;
    defer waitGpu(queue, fence, event, &fence_value) catch {};

    const viewport: c.D3D12_VIEWPORT = .{ .TopLeftX = 0, .TopLeftY = 0, .Width = width, .Height = height, .MinDepth = 0, .MaxDepth = 1 };
    const scissor: c.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    std.log.info("Hello World! DirectX 12 triangle ready. Press Escape to exit.", .{});
    var frames: u32 = 0;
    var message: c.MSG = undefined;
    while (true) {
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.message == c.WM_QUIT) return;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        if (c.IsIconic(hwnd) != 0) {
            c.Sleep(16);
            continue;
        }
        const index = swap.lpVtbl.*.GetCurrentBackBufferIndex.?(swap);
        try check(allocator.lpVtbl.*.Reset.?(allocator));
        try check(list.lpVtbl.*.Reset.?(list, allocator, pipeline));
        list.lpVtbl.*.SetGraphicsRootSignature.?(list, root);
        list.lpVtbl.*.RSSetViewports.?(list, 1, &viewport);
        list.lpVtbl.*.RSSetScissorRects.?(list, 1, &scissor);
        var barrier = transition(buffers[index], c.D3D12_RESOURCE_STATE_PRESENT, c.D3D12_RESOURCE_STATE_RENDER_TARGET);
        list.lpVtbl.*.ResourceBarrier.?(list, 1, &barrier);
        list.lpVtbl.*.OMSetRenderTargets.?(list, 1, &handles[index], c.FALSE, null);
        const clear = [4]f32{ 0.035, 0.05, 0.09, 1 };
        list.lpVtbl.*.ClearRenderTargetView.?(list, handles[index], &clear, 0, null);
        list.lpVtbl.*.IASetPrimitiveTopology.?(list, c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        list.lpVtbl.*.DrawInstanced.?(list, 3, 1, 0, 0);
        barrier = transition(buffers[index], c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_PRESENT);
        list.lpVtbl.*.ResourceBarrier.?(list, 1, &barrier);
        try check(list.lpVtbl.*.Close.?(list));
        const lists = [_]?*c.ID3D12CommandList{@ptrCast(list)};
        queue.lpVtbl.*.ExecuteCommandLists.?(queue, 1, &lists);
        try check(swap.lpVtbl.*.Present.?(swap, 1, 0));
        try waitGpu(queue, fence, event, &fence_value);
        frames += 1;
        if (frame_limit) |limit| if (frames >= limit) {
            std.log.info("Smoke test passed: {d} frames rendered and synchronized", .{frames});
            return;
        };
    }
}
