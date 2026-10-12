@echo off
setlocal
pushd "%~dp0"
where clang++ >nul 2>nul
if errorlevel 1 (
    echo clang++ was not found on PATH. Install LLVM or add its bin directory to PATH.
    popd
    pause
    exit /b 1
)
clang++ -std=c++17 -O2 -Wall -Wextra main_opengl.cpp -o hello_opengl.exe -lopengl32 -lgdi32 -luser32 -Wl,/subsystem:windows
if errorlevel 1 (
    echo OpenGL example build failed.
    popd
    pause
    exit /b 1
)
if /i "%~1"=="--build-only" (
    popd
    exit /b 0
)
hello_opengl.exe %*
set "app_exit=%errorlevel%"
popd
exit /b %app_exit%
