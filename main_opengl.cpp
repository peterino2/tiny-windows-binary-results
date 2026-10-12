#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>

// Native Win32/WGL example using the OpenGL compatibility API.
// No GLFW, loader, or other external dependencies are needed.
namespace {

struct AppState {
    HWND window = nullptr;
    HDC device_context = nullptr;
    HGLRC context = nullptr;
    bool running = true;
    UINT width = 800;
    UINT height = 600;
};

bool InitializeOpenGL(AppState& app) {
    app.device_context = GetDC(app.window);
    if (!app.device_context) return false;

    PIXELFORMATDESCRIPTOR format = {};
    format.nSize = sizeof(format);
    format.nVersion = 1;
    format.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    format.iPixelType = PFD_TYPE_RGBA;
    format.cColorBits = 32;
    format.iLayerType = PFD_MAIN_PLANE;
    const int index = ChoosePixelFormat(app.device_context, &format);
    if (!index || !SetPixelFormat(app.device_context, index, &format)) return false;

    app.context = wglCreateContext(app.device_context);
    return app.context && wglMakeCurrent(app.device_context, app.context);
}

void RenderFrame(const AppState& app) {
    glViewport(0, 0, static_cast<GLsizei>(app.width), static_cast<GLsizei>(app.height));
    glClearColor(0.08f, 0.10f, 0.14f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    // Same positions and colors as the Direct3D example in main.cpp.
    glBegin(GL_TRIANGLES);
    glColor3f(0.95f, 0.25f, 0.20f);
    glVertex3f(0.0f, 0.6f, 0.0f);
    glColor3f(0.20f, 0.45f, 0.95f);
    glVertex3f(0.6f, -0.6f, 0.0f);
    glColor3f(0.20f, 0.80f, 0.35f);
    glVertex3f(-0.6f, -0.6f, 0.0f);
    glEnd();
}

void Cleanup(AppState& app) {
    if (app.context) {
        wglMakeCurrent(nullptr, nullptr);
        wglDeleteContext(app.context);
        app.context = nullptr;
    }
    if (app.device_context) {
        ReleaseDC(app.window, app.device_context);
        app.device_context = nullptr;
    }
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* app = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (message) {
    case WM_NCCREATE: {
        const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return TRUE;
    }
    case WM_SIZE:
        if (app) {
            app->width = LOWORD(lparam);
            app->height = HIWORD(lparam);
        }
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_CLOSE:
        if (app) app->running = false;
        return 0;
    case WM_DESTROY:
        if (app) app->running = false;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR command_line, int show_command) {
    const bool smoke_test = lstrcmpW(command_line, L"--smoke-test") == 0;
    AppState app;
    const wchar_t class_name[] = L"TinyOpenGLTriangleWindow";
    WNDCLASSW window_class = {};
    window_class.style = CS_OWNDC;
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    if (!RegisterClassW(&window_class)) return 1;

    RECT rect = {0, 0, static_cast<LONG>(app.width), static_cast<LONG>(app.height)};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    app.window = CreateWindowExW(0, class_name, L"OpenGL Triangle", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
        nullptr, nullptr, instance, &app);
    if (!app.window) return 1;

    if (!InitializeOpenGL(app)) {
        if (!smoke_test) MessageBoxW(app.window, L"Could not create an OpenGL context.",
            L"OpenGL initialization failed", MB_OK | MB_ICONERROR);
        Cleanup(app);
        DestroyWindow(app.window);
        return 1;
    }

    // Check actual pixels in the back buffer, then exit without showing a window.
    if (smoke_test) {
        RenderFrame(app);
        unsigned char center[3] = {};
        glReadBuffer(GL_BACK);
        glReadPixels(app.width / 2, app.height / 2, 1, 1, GL_RGB, GL_UNSIGNED_BYTE, center);
        const bool passed = glGetError() == GL_NO_ERROR
            && center[0] > 60 && center[1] > 60 && center[2] > 60;
        Cleanup(app);
        DestroyWindow(app.window);
        return passed ? 0 : 2;
    }

    ShowWindow(app.window, show_command);
    MSG message = {};
    while (app.running) {
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) app.running = false;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (!app.running) break;
        if (app.width && app.height && !IsIconic(app.window)) {
            RenderFrame(app);
            SwapBuffers(app.device_context);
            Sleep(16);
        } else {
            WaitMessage();
        }
    }

    Cleanup(app);
    DestroyWindow(app.window);
    return 0;
}
