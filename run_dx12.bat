@echo off
setlocal
pushd "%~dp0"
where clang++ >nul 2>nul
if errorlevel 1 (
    echo clang++ was not found on PATH. Install LLVM or add its bin directory to PATH.
    popd
    pause
    exit /b 1
)
clang++ -std=c++17 -O2 -Wall -Wextra main_dx12.cpp -o hello_dx12.exe -ld3d12 -ldxgi -ld3dcompiler -luser32 -Wl,/subsystem:windows
if errorlevel 1 (
    echo Direct3D 12 example build failed.
    popd
    pause
    exit /b 1
)
if /i "%~1"=="--build-only" (
    popd
    exit /b 0
)
hello_dx12.exe %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
