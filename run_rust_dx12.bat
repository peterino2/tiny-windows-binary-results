@echo off
setlocal
pushd "%~dp0"
if not exist "rust-dx12\target\release\hello-dx12-rust.exe" (
    echo Build the samples first using build_dx12_samples.bat.
    popd
    pause
    exit /b 1
)
"rust-dx12\target\release\hello-dx12-rust.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
