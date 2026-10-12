@echo off
setlocal
pushd "%~dp0"
if not exist "hello_dx12.exe" (
    echo Build the samples first using build_dx12_samples.bat.
    popd
    pause
    exit /b 1
)
hello_dx12.exe %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
