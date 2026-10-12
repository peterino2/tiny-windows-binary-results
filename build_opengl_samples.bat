@echo off
setlocal
pushd "%~dp0"
clang++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra main_opengl.cpp -o hello_opengl.exe -lopengl32 -lgdi32 -luser32 -Wl,/subsystem:windows
if errorlevel 1 goto failed
cargo build --release --manifest-path rust-opengl\Cargo.toml
if errorlevel 1 goto failed
pushd hello-opengl
zig build -Doptimize=ReleaseSmall
set "zig_exit=%errorlevel%"
popd
if not "%zig_exit%"=="0" goto failed
echo All three OpenGL release samples built successfully.
popd
exit /b 0
:failed
echo Sample build failed.
popd
exit /b 1
