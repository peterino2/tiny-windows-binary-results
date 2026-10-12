@echo off
setlocal
pushd "%~dp0"
if not exist "hello-dx12\zig-out\bin\hello-dx12.exe" (
    echo Build the samples first using build_dx12_samples.bat.
    popd
    pause
    exit /b 1
)
"hello-dx12\zig-out\bin\hello-dx12.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
