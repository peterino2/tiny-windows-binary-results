# Triangle and hello-world samples

Windows tools on PATH: LLVM (`clang`, `clang++`), Rust (`cargo`, `rustc`), Zig 0.16, Go, and PowerShell. Install the Windows SDK for C/C++; Vulkan build dependencies are in `vendor/vulkan-sdk`.

Run from this directory to build C++, Rust, and Zig triangles:

```bat
build_opengl_samples.bat
build_dx11_samples.bat
build_dx12_samples.bat
build_vulkan_samples.bat
```

To measure all 12 apps:

it'll launch a program, meeasure it's info then leave

```bat
measure_working_set.bat
```

To measure binary sizes on disk:

```bat
build_hello_world_baselines.bat --run
```

Results: `hello-world-baselines/disk-sizes-*.csv`.
