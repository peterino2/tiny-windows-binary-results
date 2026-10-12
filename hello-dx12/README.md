# Hello World: Zig + DirectX 12

A self-contained Windows example for **Zig 0.16.0**. It opens an 800 × 600
Win32 window and draws a triangle with interpolated red, green, and blue colors
on a dark background. Press **Escape** or close the window to exit.

## Build and run

From this directory:

```powershell
zig build run
```

Build an optimized executable:

```powershell
zig build -Doptimize=ReleaseFast
.\zig-out\bin\hello-dx12.exe
```

Requires Windows 10 or later and Zig 0.16.0. Windows provides the DirectX
libraries; Zig provides the Windows headers and import libraries. No separate
Windows SDK, SDL, downloaded Zig packages, or shader files beside the executable
are needed. The build targets the Windows GNU ABI.

## How it works

- `build.zig` translates `src/windows.h` into Zig bindings using `addTranslateC`.
- `src/main.zig` creates the window, DXGI swap chain, DirectX 12 device, render
  target descriptors, root signature, pipeline, command allocator, and command list.
- `src/triangle.hlsl` is embedded into the executable and compiled at startup
  using `D3DCompile`. `SV_VertexID` generates three vertices without a vertex buffer.
- Each frame transitions the back buffer to a render target, clears it, draws
  three vertices, transitions it back, and presents with vsync.
- A fence waits for GPU completion before reusing the command allocator.
  This deliberately simple example allows one frame in flight.
- COM resources and Windows handles are released on exit.

The client size is fixed. Resizing and fullscreen are intentionally omitted
to keep swap-chain management small. If hardware device creation fails, the
example tries Microsoft's WARP software renderer.

## Smoke checks

Each command renders and synchronizes 60 frames, then exits automatically:

```powershell
zig build run -- --smoke-test
zig build run -- --warp --smoke-test
```

Force software rendering for an interactive session:

```powershell
zig build run -- --warp
```

For further reading, see Microsoft's
[basic Direct3D 12 component walkthrough](https://learn.microsoft.com/en-us/windows/win32/direct3d12/creating-a-basic-direct3d-12-component).
