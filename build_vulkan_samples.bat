@echo off
setlocal
pushd "%~dp0"
vendor\vulkan-sdk\Bin\glslc.exe -O hello-vulkan\src\triangle.vert -o hello-vulkan\src\triangle.vert.spv
if errorlevel 1 goto failed
vendor\vulkan-sdk\Bin\glslc.exe -O hello-vulkan\src\triangle.frag -o hello-vulkan\src\triangle.frag.spv
if errorlevel 1 goto failed
clang++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra -I vendor\vulkan-sdk\Include main_vulkan.cpp vendor\vulkan-sdk\Lib\vulkan-1.lib -luser32 -o hello_vulkan.exe -Wl,/subsystem:windows
if errorlevel 1 goto failed
cargo build --release --manifest-path rust-vulkan\Cargo.toml
if errorlevel 1 goto failed
pushd hello-vulkan
zig build -Doptimize=ReleaseSmall
set "zig_exit=%errorlevel%"
popd
if not "%zig_exit%"=="0" goto failed
echo All three Vulkan release samples built successfully.
popd
exit /b 0
:failed
echo Sample build failed.
popd
exit /b 1
