#![windows_subsystem = "windows"]

use windows::{
    core::{w, Result},
    Win32::{
        Foundation::*,
        Graphics::{Gdi::*, OpenGL::*},
        System::{LibraryLoader::GetModuleHandleW, Threading::Sleep},
        UI::WindowsAndMessaging::*,
    },
};

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match message {
        WM_CLOSE => { PostQuitMessage(0); LRESULT(0) }
        WM_DESTROY => { PostQuitMessage(0); LRESULT(0) }
        WM_ERASEBKGND => LRESULT(1),
        _ => DefWindowProcW(hwnd, message, wp, lp),
    }
}

struct App { window: HWND, dc: HDC, context: HGLRC }
impl Drop for App {
    fn drop(&mut self) {
        unsafe {
            if self.context.0 != 0 {
                let _ = wglMakeCurrent(HDC(0), HGLRC(0));
                let _ = wglDeleteContext(self.context);
            }
            if self.dc.0 != 0 { ReleaseDC(self.window, self.dc); }
            let _ = DestroyWindow(self.window);
        }
    }
}

unsafe fn render(width: i32, height: i32) {
    glViewport(0, 0, width, height);
    glClearColor(0.08, 0.10, 0.14, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glBegin(GL_TRIANGLES);
    glColor3f(0.95, 0.25, 0.20);
    glVertex3f(0.0, 0.6, 0.0);
    glColor3f(0.20, 0.45, 0.95);
    glVertex3f(0.6, -0.6, 0.0);
    glColor3f(0.20, 0.80, 0.35);
    glVertex3f(-0.6, -0.6, 0.0);
    glEnd();
}

unsafe fn run() -> Result<()> {
    let smoke_test = std::env::args().any(|a| a == "--smoke-test");
    let instance = HINSTANCE(GetModuleHandleW(None)?.0);
    let class_name = w!("RustOpenGLTriangle");
    let wc = WNDCLASSW {
        style: CS_OWNDC, lpfnWndProc: Some(window_proc), hInstance: instance,
        lpszClassName: class_name, hCursor: LoadCursorW(None, IDC_ARROW)?, ..Default::default()
    };
    if RegisterClassW(&wc) == 0 { return Err(windows::core::Error::from_win32()); }
    let mut rect = RECT { left: 0, top: 0, right: 800, bottom: 600 };
    AdjustWindowRect(&mut rect, WS_OVERLAPPEDWINDOW, false)?;
    let window = CreateWindowExW(WINDOW_EX_STYLE(0), class_name, w!("Rust OpenGL Triangle"),
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left,
        rect.bottom - rect.top, None, None, instance, None);
    if window.0 == 0 { return Err(windows::core::Error::from_win32()); }
    let mut app = App { window, dc: HDC(0), context: HGLRC(0) };
    app.dc = GetDC(window);
    if app.dc.0 == 0 { return Err(windows::core::Error::from_win32()); }
    let format = PIXELFORMATDESCRIPTOR {
        nSize: std::mem::size_of::<PIXELFORMATDESCRIPTOR>() as u16, nVersion: 1,
        dwFlags: PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        iPixelType: PFD_TYPE_RGBA, cColorBits: 32, iLayerType: PFD_MAIN_PLANE.0 as u8,
        ..Default::default()
    };
    let index = ChoosePixelFormat(app.dc, &format);
    if index == 0 { return Err(windows::core::Error::from_win32()); }
    SetPixelFormat(app.dc, index, &format)?;
    app.context = wglCreateContext(app.dc)?;
    wglMakeCurrent(app.dc, app.context)?;

    if smoke_test {
        render(800, 600);
        let mut pixel = [0u8; 4];
        glReadBuffer(GL_BACK);
        glReadPixels(400, 300, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.as_mut_ptr().cast());
        if glGetError() != GL_NO_ERROR || pixel[..3].iter().any(|&v| v <= 60) {
            return Err(windows::core::Error::new(E_FAIL, "Rendered pixel check failed".into()));
        }
        return Ok(());
    }

    ShowWindow(window, SW_SHOW);
    loop {
        let mut message = MSG::default();
        while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
            if message.message == WM_QUIT { return Ok(()); }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        GetClientRect(window, &mut rect)?;
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        if width > 0 && height > 0 && !IsIconic(window).as_bool() {
            render(width, height);
            SwapBuffers(app.dc)?;
            Sleep(16);
        } else { WaitMessage()?; }
    }
}

fn main() {
    if let Err(error) = unsafe { run() } {
        if !std::env::args().any(|a| a == "--smoke-test") {
            let text: Vec<u16> = format!("{error}").encode_utf16().chain(Some(0)).collect();
            unsafe { MessageBoxW(None, windows::core::PCWSTR(text.as_ptr()), w!("Rust OpenGL failed"), MB_OK | MB_ICONERROR); }
        }
        std::process::exit(1);
    }
}
