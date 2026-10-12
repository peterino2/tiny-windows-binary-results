const std = @import("std");
const c = @import("win");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

comptime {
    if (@sizeOf(c.PIXELFORMATDESCRIPTOR) != 40 or @offsetOf(c.PIXELFORMATDESCRIPTOR, "dwFlags") != 4)
        @compileError("Unexpected Windows pixel-format ABI");
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_CLOSE, c.WM_DESTROY => { c.PostQuitMessage(0); return 0; },
        c.WM_ERASEBKGND => return 1,
        else => return c.DefWindowProcW(hwnd, message, wp, lp),
    }
}

fn render(width: c.GLsizei, height: c.GLsizei) void {
    c.glViewport(0, 0, width, height);
    c.glClearColor(0.08, 0.10, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glMatrixMode(c.GL_PROJECTION);
    c.glLoadIdentity();
    c.glMatrixMode(c.GL_MODELVIEW);
    c.glLoadIdentity();
    c.glBegin(c.GL_TRIANGLES);
    c.glColor3f(0.95, 0.25, 0.20);
    c.glVertex3f(0.0, 0.6, 0.0);
    c.glColor3f(0.20, 0.45, 0.95);
    c.glVertex3f(0.6, -0.6, 0.0);
    c.glColor3f(0.20, 0.80, 0.35);
    c.glVertex3f(-0.6, -0.6, 0.0);
    c.glEnd();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    var smoke_test = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) smoke_test = true else return error.UnknownArgument;
    }
    const instance = c.GetModuleHandleW(null);
    const class_name = wide("ZigOpenGLTriangle");
    var wc = std.mem.zeroes(c.WNDCLASSW);
    wc.style = c.CS_OWNDC;
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = class_name;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&wc) == 0) return error.WindowClassFailed;
    defer _ = c.UnregisterClassW(class_name, instance);
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    if (c.AdjustWindowRect(&rect, c.WS_OVERLAPPEDWINDOW, c.FALSE) == 0) return error.WindowRectFailed;
    const window = c.CreateWindowExW(0, class_name, wide("Zig OpenGL Triangle"), c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT, c.CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
        null, null, instance, null) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(window);
    const dc = c.GetDC(window) orelse return error.DeviceContextFailed;
    defer _ = c.ReleaseDC(window, dc);
    var format = std.mem.zeroes(c.PIXELFORMATDESCRIPTOR);
    format.nSize = @sizeOf(c.PIXELFORMATDESCRIPTOR);
    format.nVersion = 1;
    format.dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER;
    format.iPixelType = c.PFD_TYPE_RGBA;
    format.cColorBits = 32;
    format.iLayerType = c.PFD_MAIN_PLANE;
    const index = c.ChoosePixelFormat(dc, &format);
    if (index == 0 or c.SetPixelFormat(dc, index, &format) == 0) return error.PixelFormatFailed;
    const context = c.wglCreateContext(dc) orelse return error.OpenGLContextFailed;
    defer _ = c.wglDeleteContext(context);
    if (c.wglMakeCurrent(dc, context) == 0) return error.MakeCurrentFailed;
    defer _ = c.wglMakeCurrent(null, null);

    if (smoke_test) {
        render(800, 600);
        var pixel: [4]u8 = @splat(0);
        c.glReadBuffer(c.GL_BACK);
        c.glReadPixels(400, 300, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixel);
        if (c.glGetError() != c.GL_NO_ERROR or pixel[0] <= 60 or pixel[1] <= 60 or pixel[2] <= 60)
            return error.RenderedPixelCheckFailed;
        return;
    }

    _ = c.ShowWindow(window, c.SW_SHOW);
    while (true) {
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.message == c.WM_QUIT) return;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        if (c.GetClientRect(window, &rect) == 0) return error.ClientRectFailed;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width > 0 and height > 0 and c.IsIconic(window) == 0) {
            render(width, height);
            if (c.SwapBuffers(dc) == 0) return error.SwapBuffersFailed;
            c.Sleep(16);
        } else {
            if (c.WaitMessage() == 0) return error.WaitMessageFailed;
        }
    }
}
