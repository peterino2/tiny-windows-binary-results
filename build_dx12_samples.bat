@echo off
setlocal
pushd "%~dp0"
clang++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra main_dx12.cpp -o hello_dx12.exe -ld3d12 -ldxgi -ld3dcompiler -luser32 -Wl,/subsystem:windows
if errorlevel 1 goto failed
cargo build --release --manifest-path rust-dx12\Cargo.toml
if errorlevel 1 goto failed
pushd hello-dx12
zig build -Doptimize=ReleaseFast
set "zig_exit=%errorlevel%"
popd
if not "%zig_exit%"=="0" goto failed
echo All three DX12 release samples built successfully.
popd
exit /b 0
:failed
echo Sample build failed.
popd
exit /b 1
