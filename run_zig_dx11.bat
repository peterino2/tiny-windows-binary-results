@echo off
setlocal
pushd "%~dp0"
if not exist "hello-dx11\zig-out\bin\hello-dx11-zig.exe" (
    echo Build the samples first using build_dx11_samples.bat.
    popd
    pause
    exit /b 1
)
"hello-dx11\zig-out\bin\hello-dx11-zig.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
