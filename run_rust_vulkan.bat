@echo off
setlocal
pushd "%~dp0"
if not exist "rust-vulkan\target\release\hello-vulkan-rust.exe" (
    echo Build the samples first using build_vulkan_samples.bat.
    popd
    pause
    exit /b 1
)
"rust-vulkan\target\release\hello-vulkan-rust.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
