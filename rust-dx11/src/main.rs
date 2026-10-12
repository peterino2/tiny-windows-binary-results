#![windows_subsystem = "windows"]
use std::slice;
use windows::{core::{w, s, Result, PCSTR}, Win32::{Foundation::*,
    Graphics::{Direct3D::*, Direct3D::Fxc::*, Direct3D11::*, Dxgi::*, Dxgi::Common::*},
    System::{LibraryLoader::GetModuleHandleW, Threading::Sleep}, UI::WindowsAndMessaging::*}};
const SHADER: &str = include_str!("../../hello-dx11/src/triangle.hlsl");
unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match message {
        WM_CLOSE | WM_DESTROY => { PostQuitMessage(0); LRESULT(0) }
        WM_KEYDOWN if wp.0 == 27 => { PostQuitMessage(0); LRESULT(0) }
        _ => DefWindowProcW(hwnd, message, wp, lp),
    }
}
struct Window(HWND);
impl Drop for Window { fn drop(&mut self) { unsafe { let _ = DestroyWindow(self.0); } } }
unsafe fn compile(entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let mut code = None; let mut errors = None;
    D3DCompile(SHADER.as_ptr().cast(), SHADER.len(), None, None, None, entry, target,
        D3DCOMPILE_ENABLE_STRICTNESS, 0, &mut code, Some(&mut errors))?;
    Ok(code.unwrap())
}
unsafe fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let smoke = args.iter().any(|a| a == "--smoke-test");
    let warp = args.iter().any(|a| a == "--warp");
    let instance = HINSTANCE(GetModuleHandleW(None)?.0);
    let name = w!("RustDx11Triangle");
    let wc = WNDCLASSW { lpfnWndProc: Some(window_proc), hInstance: instance,
        lpszClassName: name, hCursor: LoadCursorW(None, IDC_ARROW)?, ..Default::default() };
    if RegisterClassW(&wc) == 0 { return Err(windows::core::Error::from_win32()); }
    let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    let mut rect = RECT { left: 0, top: 0, right: 800, bottom: 600 };
    AdjustWindowRect(&mut rect, style, false)?;
    let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), name, w!("Rust Direct3D 11 Triangle"), style,
        CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, None, None, instance, None);
    if hwnd.0 == 0 { return Err(windows::core::Error::from_win32()); }
    let _window = Window(hwnd);
    let desc = DXGI_SWAP_CHAIN_DESC {
        BufferDesc: DXGI_MODE_DESC { Width: 800, Height: 600, Format: DXGI_FORMAT_R8G8B8A8_UNORM, ..Default::default() },
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 }, BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: 2, OutputWindow: hwnd, Windowed: TRUE, SwapEffect: DXGI_SWAP_EFFECT_DISCARD, ..Default::default()
    };
    let (mut swap, mut device, mut context) = (None, None, None);
    let driver = if warp { D3D_DRIVER_TYPE_WARP } else { D3D_DRIVER_TYPE_HARDWARE };
    if D3D11CreateDeviceAndSwapChain(None, driver, HMODULE(0), D3D11_CREATE_DEVICE_FLAG(0), None,
        D3D11_SDK_VERSION, Some(&desc), Some(&mut swap), Some(&mut device), None, Some(&mut context)).is_err() {
        D3D11CreateDeviceAndSwapChain(None, D3D_DRIVER_TYPE_WARP, HMODULE(0), D3D11_CREATE_DEVICE_FLAG(0), None,
            D3D11_SDK_VERSION, Some(&desc), Some(&mut swap), Some(&mut device), None, Some(&mut context))?;
    }
    let (swap, device, context): (IDXGISwapChain, ID3D11Device, ID3D11DeviceContext) = (swap.unwrap(), device.unwrap(), context.unwrap());
    let buffer: ID3D11Texture2D = swap.GetBuffer(0)?;
    let mut rtv = None;
    device.CreateRenderTargetView(&buffer, None, Some(&mut rtv))?;
    let rtv = rtv.unwrap();
    let vs_blob = compile(s!("VSMain"), s!("vs_5_0"))?;
    let ps_blob = compile(s!("PSMain"), s!("ps_5_0"))?;
    let (mut vs, mut ps) = (None, None);
    device.CreateVertexShader(slice::from_raw_parts(vs_blob.GetBufferPointer().cast(), vs_blob.GetBufferSize()), None, Some(&mut vs))?;
    device.CreatePixelShader(slice::from_raw_parts(ps_blob.GetBufferPointer().cast(), ps_blob.GetBufferSize()), None, Some(&mut ps))?;
    drop((vs_blob, ps_blob));
    let viewport = D3D11_VIEWPORT { Width: 800.0, Height: 600.0, MaxDepth: 1.0, ..Default::default() };
    context.RSSetViewports(Some(&[viewport]));
    context.OMSetRenderTargets(Some(&[Some(rtv.clone())]), None);
    context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context.VSSetShader(vs.as_ref(), None);
    context.PSSetShader(ps.as_ref(), None);
    ShowWindow(hwnd, SW_SHOW);
    let mut frames = 0;
    loop {
        let mut msg = MSG::default();
        while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
            if msg.message == WM_QUIT { context.ClearState(); context.Flush(); return Ok(()); }
            TranslateMessage(&msg); DispatchMessageW(&msg);
        }
        if IsIconic(hwnd).as_bool() { Sleep(16); continue; }
        context.ClearRenderTargetView(&rtv, &[0.08, 0.10, 0.14, 1.0]);
        context.Draw(3, 0);
        swap.Present(1, 0).ok()?;
        frames += 1;
        if smoke && frames >= 60 { device.GetDeviceRemovedReason()?; context.ClearState(); context.Flush(); return Ok(()); }
    }
}
fn main() {
    if let Err(error) = unsafe { run() } {
        if !std::env::args().any(|a| a == "--smoke-test") {
            let text: Vec<u16> = format!("{error}").encode_utf16().chain(Some(0)).collect();
            unsafe { MessageBoxW(None, windows::core::PCWSTR(text.as_ptr()), w!("DX11 failed"), MB_OK | MB_ICONERROR); }
        }
        std::process::exit(1);
    }
}
