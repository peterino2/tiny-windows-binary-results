@echo off
setlocal
pushd "%~dp0"
if not exist "hello_opengl.exe" (
    echo Build the samples first using build_opengl_samples.bat.
    popd
    pause
    exit /b 1
)
hello_opengl.exe %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
