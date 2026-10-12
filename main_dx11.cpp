#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "dxgi.lib")

namespace {

struct Vertex {
    float position[3];
    float color[4];
};

struct AppState {
    HWND window = nullptr;
    bool running = true;
    UINT width = 800;
    UINT height = 600;

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    IDXGISwapChain* swap_chain = nullptr;
    ID3D11RenderTargetView* render_target_view = nullptr;
    ID3D11VertexShader* vertex_shader = nullptr;
    ID3D11PixelShader* pixel_shader = nullptr;
    ID3D11InputLayout* input_layout = nullptr;
    ID3D11Buffer* vertex_buffer = nullptr;
};

template <typename T>
void SafeRelease(T*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

bool CreateRenderTarget(AppState& app) {
    ID3D11Texture2D* back_buffer = nullptr;
    HRESULT hr = app.swap_chain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&back_buffer));
    if (FAILED(hr)) {
        return false;
    }

    hr = app.device->CreateRenderTargetView(back_buffer, nullptr, &app.render_target_view);
    back_buffer->Release();
    return SUCCEEDED(hr);
}

void DestroyRenderTarget(AppState& app) {
    SafeRelease(app.render_target_view);
}

bool ResizeSwapChain(AppState& app, UINT width, UINT height) {
    if (app.swap_chain == nullptr || width == 0 || height == 0) {
        return true;
    }

    app.width = width;
    app.height = height;

    app.context->OMSetRenderTargets(0, nullptr, nullptr);
    DestroyRenderTarget(app);

    HRESULT hr = app.swap_chain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);
    if (FAILED(hr)) {
        return false;
    }

    return CreateRenderTarget(app);
}

bool CompileShader(
    const char* source,
    const char* entry_point,
    const char* target,
    ID3DBlob** shader_blob
) {
    UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;
#if defined(_DEBUG)
    flags |= D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION;
#endif

    ID3DBlob* error_blob = nullptr;
    HRESULT hr = D3DCompile(
        source,
        lstrlenA(source),
        nullptr,
        nullptr,
        nullptr,
        entry_point,
        target,
        flags,
        0,
        shader_blob,
        &error_blob
    );

    if (error_blob != nullptr) {
        OutputDebugStringA(static_cast<const char*>(error_blob->GetBufferPointer()));
        error_blob->Release();
    }

    return SUCCEEDED(hr);
}

bool CreateGraphicsResources(AppState& app) {
    static const char* vertex_shader_source =
        "struct VSInput {\n"
        "    float3 position : POSITION;\n"
        "    float4 color : COLOR;\n"
        "};\n"
        "struct PSInput {\n"
        "    float4 position : SV_POSITION;\n"
        "    float4 color : COLOR;\n"
        "};\n"
        "PSInput main(VSInput input) {\n"
        "    PSInput output;\n"
        "    output.position = float4(input.position, 1.0f);\n"
        "    output.color = input.color;\n"
        "    return output;\n"
        "}\n";

    static const char* pixel_shader_source =
        "struct PSInput {\n"
        "    float4 position : SV_POSITION;\n"
        "    float4 color : COLOR;\n"
        "};\n"
        "float4 main(PSInput input) : SV_TARGET {\n"
        "    return input.color;\n"
        "}\n";

    ID3DBlob* vertex_shader_blob = nullptr;
    ID3DBlob* pixel_shader_blob = nullptr;

    if (!CompileShader(vertex_shader_source, "main", "vs_4_0", &vertex_shader_blob)) {
        return false;
    }

    if (!CompileShader(pixel_shader_source, "main", "ps_4_0", &pixel_shader_blob)) {
        SafeRelease(vertex_shader_blob);
        return false;
    }

    HRESULT hr = app.device->CreateVertexShader(
        vertex_shader_blob->GetBufferPointer(),
        vertex_shader_blob->GetBufferSize(),
        nullptr,
        &app.vertex_shader
    );
    if (FAILED(hr)) {
        SafeRelease(vertex_shader_blob);
        SafeRelease(pixel_shader_blob);
        return false;
    }

    hr = app.device->CreatePixelShader(
        pixel_shader_blob->GetBufferPointer(),
        pixel_shader_blob->GetBufferSize(),
        nullptr,
        &app.pixel_shader
    );
    if (FAILED(hr)) {
        SafeRelease(vertex_shader_blob);
        SafeRelease(pixel_shader_blob);
        return false;
    }

    D3D11_INPUT_ELEMENT_DESC input_elements[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, offsetof(Vertex, position), D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, offsetof(Vertex, color), D3D11_INPUT_PER_VERTEX_DATA, 0},
    };

    hr = app.device->CreateInputLayout(
        input_elements,
        ARRAYSIZE(input_elements),
        vertex_shader_blob->GetBufferPointer(),
        vertex_shader_blob->GetBufferSize(),
        &app.input_layout
    );
    SafeRelease(vertex_shader_blob);
    SafeRelease(pixel_shader_blob);
    if (FAILED(hr)) {
        return false;
    }

    const Vertex triangle_vertices[] = {
        {{0.0f, 0.6f, 0.0f}, {0.95f, 0.25f, 0.20f, 1.0f}},
        {{0.6f, -0.6f, 0.0f}, {0.20f, 0.45f, 0.95f, 1.0f}},
        {{-0.6f, -0.6f, 0.0f}, {0.20f, 0.80f, 0.35f, 1.0f}},
    };

    D3D11_BUFFER_DESC buffer_desc = {};
    buffer_desc.ByteWidth = sizeof(triangle_vertices);
    buffer_desc.Usage = D3D11_USAGE_DEFAULT;
    buffer_desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;

    D3D11_SUBRESOURCE_DATA initial_data = {};
    initial_data.pSysMem = triangle_vertices;

    hr = app.device->CreateBuffer(&buffer_desc, &initial_data, &app.vertex_buffer);
    return SUCCEEDED(hr);
}

bool InitializeDirect3D(AppState& app, bool use_warp) {
    DXGI_SWAP_CHAIN_DESC swap_chain_desc = {};
    swap_chain_desc.BufferDesc.Width = app.width;
    swap_chain_desc.BufferDesc.Height = app.height;
    swap_chain_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_chain_desc.SampleDesc.Count = 1;
    swap_chain_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_chain_desc.BufferCount = 2;
    swap_chain_desc.OutputWindow = app.window;
    swap_chain_desc.Windowed = TRUE;
    swap_chain_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    UINT creation_flags = 0;
#if defined(_DEBUG)
    creation_flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    const D3D_FEATURE_LEVEL requested_feature_levels[] = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };

    D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr,
        use_warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        creation_flags,
        requested_feature_levels,
        ARRAYSIZE(requested_feature_levels),
        D3D11_SDK_VERSION,
        &swap_chain_desc,
        &app.swap_chain,
        &app.device,
        &feature_level,
        &app.context
    );

    if (FAILED(hr)) {
        hr = D3D11CreateDeviceAndSwapChain(
            nullptr,
            D3D_DRIVER_TYPE_WARP,
            nullptr,
            creation_flags,
            requested_feature_levels,
            ARRAYSIZE(requested_feature_levels),
            D3D11_SDK_VERSION,
            &swap_chain_desc,
            &app.swap_chain,
            &app.device,
            &feature_level,
            &app.context
        );
        if (FAILED(hr)) {
            return false;
        }
    }

    if (!CreateRenderTarget(app)) {
        return false;
    }

    return CreateGraphicsResources(app);
}

void RenderFrame(AppState& app) {
    const float clear_color[4] = {0.08f, 0.10f, 0.14f, 1.0f};
    app.context->OMSetRenderTargets(1, &app.render_target_view, nullptr);
    app.context->ClearRenderTargetView(app.render_target_view, clear_color);

    D3D11_VIEWPORT viewport = {};
    viewport.Width = static_cast<float>(app.width);
    viewport.Height = static_cast<float>(app.height);
    viewport.MinDepth = 0.0f;
    viewport.MaxDepth = 1.0f;
    app.context->RSSetViewports(1, &viewport);

    UINT stride = sizeof(Vertex);
    UINT offset = 0;
    app.context->IASetInputLayout(app.input_layout);
    app.context->IASetVertexBuffers(0, 1, &app.vertex_buffer, &stride, &offset);
    app.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    app.context->VSSetShader(app.vertex_shader, nullptr, 0);
    app.context->PSSetShader(app.pixel_shader, nullptr, 0);
    app.context->Draw(3, 0);
    app.swap_chain->Present(1, 0);
}

void Cleanup(AppState& app) {
    DestroyRenderTarget(app);
    SafeRelease(app.vertex_buffer);
    SafeRelease(app.input_layout);
    SafeRelease(app.pixel_shader);
    SafeRelease(app.vertex_shader);
    SafeRelease(app.swap_chain);
    SafeRelease(app.context);
    SafeRelease(app.device);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    AppState* app = reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (message) {
    case WM_NCCREATE: {
        const CREATESTRUCTW* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        return TRUE;
    }
    case WM_SIZE:
        if (app != nullptr) {
            ResizeSwapChain(*app, LOWORD(lparam), HIWORD(lparam));
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (app != nullptr) {
            app->running = false;
        }
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR command_line, int show_command) {
    const bool smoke_test = wcsstr(command_line, L"--smoke-test") != nullptr;
    const bool use_warp = wcsstr(command_line, L"--warp") != nullptr;
    unsigned frames = 0;
    AppState app;

    const wchar_t class_name[] = L"TinyDx11TriangleWindow";
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);

    if (RegisterClassW(&window_class) == 0) {
        return 1;
    }

    RECT desired_rect = {0, 0, static_cast<LONG>(app.width), static_cast<LONG>(app.height)};
    AdjustWindowRect(&desired_rect, WS_OVERLAPPEDWINDOW, FALSE);

    app.window = CreateWindowExW(
        0,
        class_name,
        L"Direct3D 11 Triangle",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        desired_rect.right - desired_rect.left,
        desired_rect.bottom - desired_rect.top,
        nullptr,
        nullptr,
        instance,
        &app
    );

    if (app.window == nullptr) {
        return 1;
    }

    ShowWindow(app.window, show_command);

    if (!InitializeDirect3D(app, use_warp)) {
        Cleanup(app);
        return 1;
    }

    MSG message = {};
    while (app.running) {
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                app.running = false;
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        if (!app.running) {
            break;
        }

        RenderFrame(app);
        if (smoke_test && ++frames >= 60) break;
    }

    Cleanup(app);
    return 0;
}
