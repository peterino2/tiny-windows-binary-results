@echo off
setlocal
pushd "%~dp0"
if not exist "rust-opengl\target\release\hello-opengl-rust.exe" (
    echo Build the samples first using build_opengl_samples.bat.
    popd
    pause
    exit /b 1
)
"rust-opengl\target\release\hello-opengl-rust.exe" %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
