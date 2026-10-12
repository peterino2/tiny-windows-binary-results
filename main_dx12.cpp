#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <stdexcept>

// Native Win32/D3D12 triangle; requires only the Windows SDK.
// Uses the command-list/barrier/fence flow described in Microsoft's guide:
// https://learn.microsoft.com/en-us/windows/win32/direct3d12/creating-a-basic-direct3d-12-component
namespace {
using Microsoft::WRL::ComPtr;
constexpr UINT frame_count = 2;
constexpr DXGI_FORMAT color_format = DXGI_FORMAT_R8G8B8A8_UNORM;

void Check(HRESULT result) {
    if (FAILED(result)) {
        char message[80];
        std::snprintf(message, sizeof(message), "Direct3D 12 failed (HRESULT 0x%08lX).",
            static_cast<unsigned long>(result));
        throw std::runtime_error(message);
    }
}

struct Vertex { float position[3]; float color[4]; };

struct AppState {
    HWND window = nullptr;
    bool running = true;
    UINT width = 800, height = 600;
    UINT buffer_width = 800, buffer_height = 600;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<IDXGISwapChain3> swap_chain;
    ComPtr<ID3D12DescriptorHeap> rtv_heap;
    ComPtr<ID3D12Resource> targets[frame_count];
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12RootSignature> root_signature;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12Resource> vertices;
    D3D12_VERTEX_BUFFER_VIEW vertex_view = {};
    ComPtr<ID3D12Fence> fence;
    UINT64 fence_value = 0;
    HANDLE fence_event = nullptr;
    UINT rtv_stride = 0;

    ~AppState() { if (fence_event) CloseHandle(fence_event); }
};

void WaitForGPU(AppState& app) {
    // Serialize frames to keep this small example's allocator/resource lifetime simple.
    Check(app.queue->Signal(app.fence.Get(), ++app.fence_value));
    if (app.fence->GetCompletedValue() < app.fence_value) {
        Check(app.fence->SetEventOnCompletion(app.fence_value, app.fence_event));
        if (WaitForSingleObject(app.fence_event, 10000) != WAIT_OBJECT_0)
            throw std::runtime_error("Timed out waiting for the Direct3D 12 GPU.");
    }
    Check(app.device->GetDeviceRemovedReason());
}

void CreateTargets(AppState& app) {
    auto handle = app.rtv_heap->GetCPUDescriptorHandleForHeapStart();
    for (UINT i = 0; i < frame_count; ++i) {
        Check(app.swap_chain->GetBuffer(i, IID_PPV_ARGS(&app.targets[i])));
        app.device->CreateRenderTargetView(app.targets[i].Get(), nullptr, handle);
        handle.ptr += app.rtv_stride;
    }
}

ComPtr<ID3D12Resource> CreateBuffer(AppState& app, UINT64 size,
    D3D12_HEAP_TYPE heap_type, D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES heap = {};
    heap.Type = heap_type;
    heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size;
    desc.Height = 1;
    desc.DepthOrArraySize = desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> buffer;
    Check(app.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE,
        &desc, state, nullptr, IID_PPV_ARGS(&buffer)));
    return buffer;
}

void InitializeDirect3D(AppState& app, bool use_warp) {
    ComPtr<IDXGIFactory4> factory;
    Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    HRESULT result = E_FAIL;
    if (!use_warp) {
        for (UINT i = 0; ; ++i) {
            ComPtr<IDXGIAdapter1> adapter;
            const HRESULT enumeration = factory->EnumAdapters1(i, &adapter);
            if (enumeration == DXGI_ERROR_NOT_FOUND) break;
            Check(enumeration);
            DXGI_ADAPTER_DESC1 desc = {};
            Check(adapter->GetDesc1(&desc));
            if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            result = D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                IID_PPV_ARGS(&app.device));
            if (SUCCEEDED(result)) break;
        }
    }
    if (FAILED(result)) {
        ComPtr<IDXGIAdapter> warp;
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)));
        Check(D3D12CreateDevice(warp.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&app.device)));
    }

    D3D12_COMMAND_QUEUE_DESC queue_desc = {};
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    Check(app.device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&app.queue)));
    DXGI_SWAP_CHAIN_DESC1 swap_desc = {};
    swap_desc.Width = app.buffer_width;
    swap_desc.Height = app.buffer_height;
    swap_desc.Format = color_format;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = frame_count;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ComPtr<IDXGISwapChain1> swap_chain;
    Check(factory->CreateSwapChainForHwnd(app.queue.Get(), app.window, &swap_desc,
        nullptr, nullptr, &swap_chain));
    Check(swap_chain.As(&app.swap_chain));
    Check(factory->MakeWindowAssociation(app.window, DXGI_MWA_NO_ALT_ENTER));

    D3D12_DESCRIPTOR_HEAP_DESC rtv_desc = {};
    rtv_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtv_desc.NumDescriptors = frame_count;
    Check(app.device->CreateDescriptorHeap(&rtv_desc, IID_PPV_ARGS(&app.rtv_heap)));
    app.rtv_stride = app.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    CreateTargets(app);

    D3D12_ROOT_SIGNATURE_DESC root_desc = {};
    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> root_blob, errors;
    Check(D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1,
        &root_blob, &errors));
    Check(app.device->CreateRootSignature(0, root_blob->GetBufferPointer(),
        root_blob->GetBufferSize(), IID_PPV_ARGS(&app.root_signature)));

    const char* shader =
        "struct Input { float3 position : POSITION; float4 color : COLOR; };"
        "struct Output { float4 position : SV_POSITION; float4 color : COLOR; };"
        "Output VSMain(Input v) { Output o; o.position = float4(v.position, 1);"
        "o.color = v.color; return o; }"
        "float4 PSMain(Output v) : SV_TARGET { return v.color; }";
    ComPtr<ID3DBlob> vs, ps;
    Check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr,
        "VSMain", "vs_5_0", D3DCOMPILE_ENABLE_STRICTNESS, 0, &vs, &errors));
    Check(D3DCompile(shader, std::strlen(shader), nullptr, nullptr, nullptr,
        "PSMain", "ps_5_0", D3DCOMPILE_ENABLE_STRICTNESS, 0, &ps, &errors));
    const D3D12_INPUT_ELEMENT_DESC input[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, offsetof(Vertex, position), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, offsetof(Vertex, color), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
    };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc = {};
    pipeline_desc.pRootSignature = app.root_signature.Get();
    pipeline_desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
    pipeline_desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
    pipeline_desc.InputLayout = {input, ARRAYSIZE(input)};
    pipeline_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pipeline_desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pipeline_desc.RasterizerState.DepthClipEnable = TRUE;
    auto& blend = pipeline_desc.BlendState.RenderTarget[0];
    blend.SrcBlend = blend.SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.DestBlend = blend.DestBlendAlpha = D3D12_BLEND_ZERO;
    blend.BlendOp = blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    blend.LogicOp = D3D12_LOGIC_OP_NOOP;
    blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pipeline_desc.DepthStencilState.DepthEnable = FALSE;
    pipeline_desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    pipeline_desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    pipeline_desc.DepthStencilState.StencilEnable = FALSE;
    pipeline_desc.SampleMask = UINT_MAX;
    pipeline_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipeline_desc.NumRenderTargets = 1;
    pipeline_desc.RTVFormats[0] = color_format;
    pipeline_desc.SampleDesc.Count = 1;
    Check(app.device->CreateGraphicsPipelineState(&pipeline_desc, IID_PPV_ARGS(&app.pipeline)));

    Check(app.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&app.allocator)));
    Check(app.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, app.allocator.Get(),
        app.pipeline.Get(), IID_PPV_ARGS(&app.commands)));
    Check(app.commands->Close());

    const Vertex triangle[] = {
        {{0.0f, 0.6f, 0.0f}, {0.95f, 0.25f, 0.20f, 1.0f}},
        {{0.6f, -0.6f, 0.0f}, {0.20f, 0.45f, 0.95f, 1.0f}},
        {{-0.6f, -0.6f, 0.0f}, {0.20f, 0.80f, 0.35f, 1.0f}},
    };
    app.vertices = CreateBuffer(app, sizeof(triangle), D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    void* mapped = nullptr;
    const D3D12_RANGE no_read = {0, 0};
    Check(app.vertices->Map(0, &no_read, &mapped));
    std::memcpy(mapped, triangle, sizeof(triangle));
    app.vertices->Unmap(0, nullptr);
    app.vertex_view = {app.vertices->GetGPUVirtualAddress(), sizeof(triangle), sizeof(Vertex)};

    Check(app.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&app.fence)));
    app.fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!app.fence_event) Check(HRESULT_FROM_WIN32(GetLastError()));
}

void Resize(AppState& app) {
    if (app.width == app.buffer_width && app.height == app.buffer_height) return;
    WaitForGPU(app);
    for (auto& target : app.targets) target.Reset();
    Check(app.swap_chain->ResizeBuffers(frame_count, app.width, app.height, color_format, 0));
    app.buffer_width = app.width;
    app.buffer_height = app.height;
    CreateTargets(app);
}

void Transition(AppState& app, ID3D12Resource* resource,
    D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition = {resource, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, before, after};
    app.commands->ResourceBarrier(1, &barrier);
}

void RenderFrame(AppState& app, bool smoke_test = false) {
    const UINT index = app.swap_chain->GetCurrentBackBufferIndex();
    auto* target = app.targets[index].Get();
    Check(app.allocator->Reset());
    Check(app.commands->Reset(app.allocator.Get(), app.pipeline.Get()));
    app.commands->SetGraphicsRootSignature(app.root_signature.Get());
    const D3D12_VIEWPORT viewport = {0, 0, static_cast<float>(app.buffer_width),
        static_cast<float>(app.buffer_height), 0, 1};
    const D3D12_RECT scissor = {0, 0, static_cast<LONG>(app.buffer_width), static_cast<LONG>(app.buffer_height)};
    app.commands->RSSetViewports(1, &viewport);
    app.commands->RSSetScissorRects(1, &scissor);
    Transition(app, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto rtv = app.rtv_heap->GetCPUDescriptorHandleForHeapStart();
    rtv.ptr += index * app.rtv_stride;
    app.commands->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    const float clear_color[] = {0.08f, 0.10f, 0.14f, 1.0f};
    app.commands->ClearRenderTargetView(rtv, clear_color, 0, nullptr);
    app.commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    app.commands->IASetVertexBuffers(0, 1, &app.vertex_view);
    app.commands->DrawInstanced(3, 1, 0, 0);

    ComPtr<ID3D12Resource> readback;
    if (smoke_test) {
        // Copy one center pixel to verify real GPU rendering, not just initialization.
        readback = CreateBuffer(app, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT,
            D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
        Transition(app, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION source = {}, destination = {};
        source.pResource = target;
        source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        destination.pResource = readback.Get();
        destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        destination.PlacedFootprint.Footprint = {color_format, 1, 1, 1, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT};
        const UINT x = app.buffer_width / 2, y = app.buffer_height / 2;
        const D3D12_BOX box = {x, y, 0, x + 1, y + 1, 1};
        app.commands->CopyTextureRegion(&destination, 0, 0, 0, &source, &box);
        Transition(app, target, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
    } else {
        Transition(app, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
    }
    Check(app.commands->Close());
    ID3D12CommandList* lists[] = {app.commands.Get()};
    app.queue->ExecuteCommandLists(1, lists);
    // Always finish submitted work before resetting the allocator or releasing resources.
    WaitForGPU(app);
    if (!smoke_test) {
        Check(app.swap_chain->Present(1, 0));
    } else {
        void* mapped = nullptr;
        const D3D12_RANGE range = {0, 4};
        Check(readback->Map(0, &range, &mapped));
        const auto* pixel = static_cast<const unsigned char*>(mapped);
        const bool passed = pixel[0] > 60 && pixel[1] > 60 && pixel[2] > 60 && pixel[3] == 255;
        const D3D12_RANGE no_write = {0, 0};
        readback->Unmap(0, &no_write);
        if (!passed) throw std::runtime_error("Direct3D 12 rendered-pixel check failed.");
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
        if (app) { app->width = LOWORD(lparam); app->height = HIWORD(lparam); }
        return 0;
    case WM_ERASEBKGND: return 1;
    case WM_CLOSE:
        if (app) app->running = false;
        return 0;
    case WM_DESTROY:
        if (app) app->running = false;
        PostQuitMessage(0);
        return 0;
    default: return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR command_line, int show_command) {
    const bool smoke_test = wcsstr(command_line, L"--smoke-test") != nullptr;
    const bool use_warp = wcsstr(command_line, L"--warp") != nullptr;
    AppState app;
    const wchar_t class_name[] = L"TinyDx12TriangleWindow";
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    if (!RegisterClassW(&window_class)) return 1;
    RECT rect = {0, 0, static_cast<LONG>(app.width), static_cast<LONG>(app.height)};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    app.window = CreateWindowExW(0, class_name, L"Direct3D 12 Triangle", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
        nullptr, nullptr, instance, &app);
    if (!app.window) return 1;

    int exit_code = 0;
    try {
        InitializeDirect3D(app, use_warp);
        if (smoke_test) {
            RenderFrame(app, true);
            // Also verify that resizing/recreating the back buffers still renders correctly.
            app.width = 640;
            app.height = 480;
            Resize(app);
            RenderFrame(app, true);
        } else {
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
                    Resize(app);
                    RenderFrame(app);
                } else {
                    WaitMessage();
                }
            }
        }
        WaitForGPU(app);
    } catch (const std::exception& error) {
        OutputDebugStringA(error.what());
        if (!smoke_test) MessageBoxA(app.window, error.what(), "Direct3D 12 failed", MB_OK | MB_ICONERROR);
        exit_code = 1;
    }
    // Drop swap-chain references before destroying its window.
    for (auto& target : app.targets) target.Reset();
    app.swap_chain.Reset();
    DestroyWindow(app.window);
    return exit_code;
}
