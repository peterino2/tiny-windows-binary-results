@echo off
setlocal
pushd "%~dp0"
if not exist "hello_vulkan.exe" (
    echo Build the samples first using build_vulkan_samples.bat.
    popd
    pause
    exit /b 1
)
"hello_vulkan.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
