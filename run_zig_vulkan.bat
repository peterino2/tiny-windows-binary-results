@echo off
setlocal
pushd "%~dp0"
if not exist "hello-vulkan\zig-out\bin\hello-vulkan-zig.exe" (
    echo Build the samples first using build_vulkan_samples.bat.
    popd
    pause
    exit /b 1
)
"hello-vulkan\zig-out\bin\hello-vulkan-zig.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
