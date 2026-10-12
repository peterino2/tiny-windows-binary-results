@echo off
setlocal
pushd "%~dp0"
if not exist "hello-opengl\zig-out\bin\hello-opengl-zig.exe" (
    echo Build the samples first using build_opengl_samples.bat.
    popd
    pause
    exit /b 1
)
"hello-opengl\zig-out\bin\hello-opengl-zig.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
