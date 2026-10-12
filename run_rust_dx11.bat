@echo off
setlocal
pushd "%~dp0"
if not exist "rust-dx11\target\release\hello-dx11-rust.exe" (
    echo Build the samples first using build_dx11_samples.bat.
    popd
    pause
    exit /b 1
)
"rust-dx11\target\release\hello-dx11-rust.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
