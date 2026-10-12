const std = @import("std");
const c = @import("win");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const shader = @embedFile("triangle.hlsl");
// Keep this one interface ID local instead of linking the dxguid/CRT library.
const texture_iid: c.GUID = .{ .Data1 = 0x6f15aaf2, .Data2 = 0xd208, .Data3 = 0x4e89, .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };
fn check(hr: c.HRESULT) !void { if (hr < 0) return error.DirectXFailure; }
fn release(obj: anytype) void { _ = obj.lpVtbl.*.Release.?(obj); }
fn windowProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CLOSE, c.WM_DESTROY => { c.PostQuitMessage(0); return 0; },
        c.WM_KEYDOWN => if (wp == c.VK_ESCAPE) { c.PostQuitMessage(0); return 0; },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn compile(entry: [*:0]const u8, target: [*:0]const u8) !*c.ID3DBlob {
    var code: ?*c.ID3DBlob = null;
    var errors: ?*c.ID3DBlob = null;
    defer if (errors) |blob| release(blob);
    try check(c.D3DCompile(shader.ptr, shader.len, null, null, null, entry, target, c.D3DCOMPILE_ENABLE_STRICTNESS, 0, &code, &errors));
    return code.?;
}
pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var smoke = false;
    var warp = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) smoke = true else if (std.mem.eql(u8, arg, "--warp")) warp = true else return error.UnknownArgument;
    }
    const instance = c.GetModuleHandleW(null);
    const name = wide("ZigDx11Triangle");
    var wc = std.mem.zeroes(c.WNDCLASSW);
    wc.lpfnWndProc = windowProc; wc.hInstance = instance; wc.lpszClassName = name;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&wc) == 0) return error.WindowClassFailed;
    defer _ = c.UnregisterClassW(name, instance);
    const style = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    if (c.AdjustWindowRect(&rect, style, c.FALSE) == 0) return error.WindowRectFailed;
    const hwnd = c.CreateWindowExW(0, name, wide("Zig Direct3D 11 Triangle"), style, c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top, null, null, instance, null) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    var desc = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC);
    desc.BufferDesc.Width = 800; desc.BufferDesc.Height = 600; desc.BufferDesc.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2; desc.OutputWindow = hwnd; desc.Windowed = c.TRUE; desc.SwapEffect = c.DXGI_SWAP_EFFECT_DISCARD;
    var swap: ?*c.IDXGISwapChain = null;
    var device: ?*c.ID3D11Device = null;
    var ctx: ?*c.ID3D11DeviceContext = null;
    var hr = c.D3D11CreateDeviceAndSwapChain(null, if (warp) c.D3D_DRIVER_TYPE_WARP else c.D3D_DRIVER_TYPE_HARDWARE,
        null, 0, null, 0, c.D3D11_SDK_VERSION, &desc, &swap, &device, null, &ctx);
    if (hr < 0 and !warp) hr = c.D3D11CreateDeviceAndSwapChain(null, c.D3D_DRIVER_TYPE_WARP,
        null, 0, null, 0, c.D3D11_SDK_VERSION, &desc, &swap, &device, null, &ctx);
    try check(hr);
    const s = swap.?; const d = device.?; const context = ctx.?;
    defer release(s); defer release(d); defer release(context);
    var buffer: *c.ID3D11Texture2D = undefined;
    try check(s.lpVtbl.*.GetBuffer.?(s, 0, &texture_iid, @ptrCast(&buffer)));
    defer release(buffer);
    var rtv: ?*c.ID3D11RenderTargetView = null;
    try check(d.lpVtbl.*.CreateRenderTargetView.?(d, @ptrCast(buffer), null, &rtv));
    defer release(rtv.?);
    var vs: ?*c.ID3D11VertexShader = null;
    var ps: ?*c.ID3D11PixelShader = null;
    {
        const blob = try compile("VSMain", "vs_5_0"); defer release(blob);
        try check(d.lpVtbl.*.CreateVertexShader.?(d, blob.lpVtbl.*.GetBufferPointer.?(blob), blob.lpVtbl.*.GetBufferSize.?(blob), null, &vs));
    }
    defer release(vs.?);
    {
        const blob = try compile("PSMain", "ps_5_0"); defer release(blob);
        try check(d.lpVtbl.*.CreatePixelShader.?(d, blob.lpVtbl.*.GetBufferPointer.?(blob), blob.lpVtbl.*.GetBufferSize.?(blob), null, &ps));
    }
    defer release(ps.?);
    defer { context.lpVtbl.*.ClearState.?(context); context.lpVtbl.*.Flush.?(context); }
    const viewport: c.D3D11_VIEWPORT = .{ .TopLeftX = 0, .TopLeftY = 0, .Width = 800, .Height = 600, .MinDepth = 0, .MaxDepth = 1 };
    context.lpVtbl.*.RSSetViewports.?(context, 1, &viewport);
    context.lpVtbl.*.OMSetRenderTargets.?(context, 1, &rtv, null);
    context.lpVtbl.*.IASetPrimitiveTopology.?(context, c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context.lpVtbl.*.VSSetShader.?(context, vs, null, 0);
    context.lpVtbl.*.PSSetShader.?(context, ps, null, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    var frames: u32 = 0;
    while (true) {
        var msg: c.MSG = undefined;
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) return;
            _ = c.TranslateMessage(&msg); _ = c.DispatchMessageW(&msg);
        }
        if (c.IsIconic(hwnd) != 0) { c.Sleep(16); continue; }
        const clear = [4]f32{ 0.08, 0.10, 0.14, 1 };
        context.lpVtbl.*.ClearRenderTargetView.?(context, rtv, &clear);
        context.lpVtbl.*.Draw.?(context, 3, 0);
        try check(s.lpVtbl.*.Present.?(s, 1, 0));
        frames += 1;
        if (smoke and frames >= 60) { try check(d.lpVtbl.*.GetDeviceRemovedReason.?(d)); return; }
    }
}
