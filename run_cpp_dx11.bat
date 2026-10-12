@echo off
setlocal
pushd "%~dp0"
if not exist "hello_dx11.exe" (
    echo Build the samples first using build_dx11_samples.bat.
    popd
    pause
    exit /b 1
)
"hello_dx11.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
