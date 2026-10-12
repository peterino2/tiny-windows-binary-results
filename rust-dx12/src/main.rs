#![windows_subsystem = "windows"]

use std::{mem::ManuallyDrop, slice};
use windows::{
    core::{w, s, ComInterface, IUnknown, Result, PCSTR},
    Win32::{
        Foundation::*,
        Graphics::{Direct3D::*, Direct3D::Fxc::*, Direct3D12::*, Dxgi::*, Dxgi::Common::*},
        System::{LibraryLoader::GetModuleHandleW, Threading::*},
        UI::WindowsAndMessaging::*,
    },
};

// Embed the same vertex-ID shader as the Zig sample, with no vertex buffer.
const SHADER: &str = include_str!("../../hello-dx12/src/triangle.hlsl");

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match message {
        WM_CLOSE => { PostQuitMessage(0); LRESULT(0) }
        WM_KEYDOWN if wp.0 == 27 => { PostQuitMessage(0); LRESULT(0) }
        WM_DESTROY => { PostQuitMessage(0); LRESULT(0) }
        _ => DefWindowProcW(hwnd, message, wp, lp),
    }
}

unsafe fn compile(entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let mut code = None;
    let mut errors = None;
    D3DCompile(SHADER.as_ptr().cast(), SHADER.len(), s!("triangle.hlsl"), None,
        None, entry, target, D3DCOMPILE_ENABLE_STRICTNESS, 0, &mut code, Some(&mut errors))?;
    Ok(code.unwrap())
}

unsafe fn wait_gpu(queue: &ID3D12CommandQueue, fence: &ID3D12Fence, event: HANDLE, value: &mut u64) -> Result<()> {
    *value += 1;
    queue.Signal(fence, *value)?;
    if fence.GetCompletedValue() < *value {
        fence.SetEventOnCompletion(*value, event)?;
        if WaitForSingleObject(event, 10000) != WAIT_OBJECT_0 {
            return Err(windows::core::Error::new(E_FAIL, "GPU fence wait failed".into()));
        }
    }
    Ok(())
}

unsafe fn transition(list: &ID3D12GraphicsCommandList, target: &ID3D12Resource,
    before: D3D12_RESOURCE_STATES, after: D3D12_RESOURCE_STATES) {
    // ManuallyDrop fields in Windows union bindings do not release their COM references.
    let mut barrier = D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        Anonymous: D3D12_RESOURCE_BARRIER_0 {
            Transition: ManuallyDrop::new(D3D12_RESOURCE_TRANSITION_BARRIER {
                pResource: ManuallyDrop::new(Some(target.clone())),
                Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                StateBefore: before, StateAfter: after,
            }),
        },
        ..Default::default()
    };
    list.ResourceBarrier(slice::from_ref(&barrier));
    ManuallyDrop::drop(&mut (*barrier.Anonymous.Transition).pResource);
}

struct Window(HWND);
impl Drop for Window {
    fn drop(&mut self) { unsafe { let _ = DestroyWindow(self.0); } }
}
struct Event(HANDLE);
impl Drop for Event {
    fn drop(&mut self) { unsafe { let _ = CloseHandle(self.0); } }
}

unsafe fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let smoke_test = args.iter().any(|a| a == "--smoke-test");
    let use_warp = args.iter().any(|a| a == "--warp");
    if args.iter().any(|a| a != "--smoke-test" && a != "--warp") {
        return Err(windows::core::Error::new(E_INVALIDARG, "Unknown argument".into()));
    }
    let instance = HINSTANCE(GetModuleHandleW(None)?.0);
    let class_name = w!("RustDx12Triangle");
    let wc = WNDCLASSW {
        lpfnWndProc: Some(window_proc), hInstance: instance, lpszClassName: class_name,
        hCursor: LoadCursorW(None, IDC_ARROW)?, ..Default::default()
    };
    if RegisterClassW(&wc) == 0 { return Err(windows::core::Error::from_win32()); }
    let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    let mut rect = RECT { left: 0, top: 0, right: 800, bottom: 600 };
    AdjustWindowRect(&mut rect, style, false)?;
    let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), class_name,
        w!("Hello World - Rust + DirectX 12"), style, CW_USEDEFAULT, CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top, None, None, instance, None);
    if hwnd.0 == 0 { return Err(windows::core::Error::from_win32()); }
    let _window = Window(hwnd);

    let factory: IDXGIFactory4 = CreateDXGIFactory2(0)?;
    let mut adapter: Option<IUnknown> = None;
    if use_warp { adapter = Some(factory.EnumWarpAdapter()?); }
    let mut device: Option<ID3D12Device> = None;
    if D3D12CreateDevice(adapter.as_ref(), D3D_FEATURE_LEVEL_11_0, &mut device).is_err() {
        adapter = Some(factory.EnumWarpAdapter()?);
        D3D12CreateDevice(adapter.as_ref(), D3D_FEATURE_LEVEL_11_0, &mut device)?;
    }
    let device = device.unwrap();
    let queue: ID3D12CommandQueue = device.CreateCommandQueue(&D3D12_COMMAND_QUEUE_DESC {
        Type: D3D12_COMMAND_LIST_TYPE_DIRECT, ..Default::default()
    })?;
    let swap_desc = DXGI_SWAP_CHAIN_DESC1 {
        Width: 800, Height: 600, Format: DXGI_FORMAT_R8G8B8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: 2,
        SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD, ..Default::default()
    };
    let swap: IDXGISwapChain3 = factory.CreateSwapChainForHwnd(&queue, hwnd,
        &swap_desc, None, None)?.cast()?;
    factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER)?;
    let heap: ID3D12DescriptorHeap = device.CreateDescriptorHeap(&D3D12_DESCRIPTOR_HEAP_DESC {
        Type: D3D12_DESCRIPTOR_HEAP_TYPE_RTV, NumDescriptors: 2, ..Default::default()
    })?;
    let start = heap.GetCPUDescriptorHandleForHeapStart();
    let stride = device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV) as usize;
    let buffers: [ID3D12Resource; 2] = [swap.GetBuffer(0)?, swap.GetBuffer(1)?];
    let handles = [start, D3D12_CPU_DESCRIPTOR_HANDLE { ptr: start.ptr + stride }];
    for i in 0..2 { device.CreateRenderTargetView(&buffers[i], None, handles[i]); }

    let mut root_blob = None;
    let mut root_errors = None;
    D3D12SerializeRootSignature(&D3D12_ROOT_SIGNATURE_DESC::default(),
        D3D_ROOT_SIGNATURE_VERSION_1, &mut root_blob, Some(&mut root_errors))?;
    let root_blob = root_blob.unwrap();
    let root: ID3D12RootSignature = device.CreateRootSignature(0,
        slice::from_raw_parts(root_blob.GetBufferPointer().cast(), root_blob.GetBufferSize()))?;
    let vs = compile(s!("VSMain"), s!("vs_5_0"))?;
    let ps = compile(s!("PSMain"), s!("ps_5_0"))?;
    let mut desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC {
        pRootSignature: ManuallyDrop::new(Some(root.clone())),
        VS: D3D12_SHADER_BYTECODE { pShaderBytecode: vs.GetBufferPointer(), BytecodeLength: vs.GetBufferSize() },
        PS: D3D12_SHADER_BYTECODE { pShaderBytecode: ps.GetBufferPointer(), BytecodeLength: ps.GetBufferSize() },
        SampleMask: u32::MAX,
        RasterizerState: D3D12_RASTERIZER_DESC {
            FillMode: D3D12_FILL_MODE_SOLID, CullMode: D3D12_CULL_MODE_NONE,
            DepthClipEnable: TRUE, ..Default::default()
        },
        DepthStencilState: D3D12_DEPTH_STENCIL_DESC {
            DepthFunc: D3D12_COMPARISON_FUNC_ALWAYS, ..Default::default()
        },
        PrimitiveTopologyType: D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
        NumRenderTargets: 1, SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        ..Default::default()
    };
    desc.RTVFormats[0] = swap_desc.Format;
    desc.BlendState.RenderTarget[0] = D3D12_RENDER_TARGET_BLEND_DESC {
        SrcBlend: D3D12_BLEND_ONE, DestBlend: D3D12_BLEND_ZERO, BlendOp: D3D12_BLEND_OP_ADD,
        SrcBlendAlpha: D3D12_BLEND_ONE, DestBlendAlpha: D3D12_BLEND_ZERO, BlendOpAlpha: D3D12_BLEND_OP_ADD,
        LogicOp: D3D12_LOGIC_OP_NOOP, RenderTargetWriteMask: D3D12_COLOR_WRITE_ENABLE_ALL.0 as u8,
        ..Default::default()
    };
    let pipeline_result: Result<ID3D12PipelineState> = device.CreateGraphicsPipelineState(&desc);
    ManuallyDrop::drop(&mut desc.pRootSignature);
    let pipeline = pipeline_result?;
    let allocator: ID3D12CommandAllocator = device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT)?;
    let list: ID3D12GraphicsCommandList = device.CreateCommandList(0,
        D3D12_COMMAND_LIST_TYPE_DIRECT, &allocator, &pipeline)?;
    list.Close()?;
    let fence: ID3D12Fence = device.CreateFence(0, D3D12_FENCE_FLAG_NONE)?;
    let event = Event(CreateEventW(None, false, false, None)?);
    let mut fence_value = 0;
    // Release startup shader blobs before the interactive measurement period.
    drop((root_blob, root_errors, vs, ps));
    let viewport = D3D12_VIEWPORT { Width: 800.0, Height: 600.0, MaxDepth: 1.0, ..Default::default() };
    let scissor = RECT { left: 0, top: 0, right: 800, bottom: 600 };
    ShowWindow(hwnd, SW_SHOW);
    let mut frames = 0;
    let rendering = (|| -> Result<()> {
        loop {
            let mut message = MSG::default();
            while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                if message.message == WM_QUIT { return Ok(()); }
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if IsIconic(hwnd).as_bool() { Sleep(16); continue; }
            let index = swap.GetCurrentBackBufferIndex() as usize;
            allocator.Reset()?;
            list.Reset(&allocator, &pipeline)?;
            list.SetGraphicsRootSignature(&root);
            list.RSSetViewports(&[viewport]);
            list.RSSetScissorRects(&[scissor]);
            transition(&list, &buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
            list.OMSetRenderTargets(1, Some(&handles[index]), false, None);
            list.ClearRenderTargetView(handles[index], &[0.035, 0.05, 0.09, 1.0], None);
            list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            list.DrawInstanced(3, 1, 0, 0);
            transition(&list, &buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
            list.Close()?;
            let base: ID3D12CommandList = list.cast()?;
            queue.ExecuteCommandLists(&[Some(base)]);
            // Wait before any error path can release submitted GPU resources.
            wait_gpu(&queue, &fence, event.0, &mut fence_value)?;
            swap.Present(1, 0).ok()?;
            frames += 1;
            if smoke_test && frames >= 60 { return Ok(()); }
        }
    })();
    let drained = wait_gpu(&queue, &fence, event.0, &mut fence_value);
    rendering.and(drained)
}

fn main() {
    if let Err(error) = unsafe { run() } {
        if !std::env::args().any(|a| a == "--smoke-test") {
            let text: Vec<u16> = format!("{error}").encode_utf16().chain(Some(0)).collect();
            unsafe { MessageBoxW(None, windows::core::PCWSTR(text.as_ptr()), w!("Rust DirectX 12 failed"), MB_OK | MB_ICONERROR); }
        }
        std::process::exit(1);
    }
}
