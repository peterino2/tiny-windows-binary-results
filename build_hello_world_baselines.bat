@echo off
setlocal EnableExtensions
pushd "%~dp0hello-world-baselines" || exit /b 1

for %%T in (clang clang++ rustc go zig powershell) do (
    where %%T >nul 2>nul
    if errorlevel 1 (
        echo Required tool not found on PATH: %%T
        goto failed
    )
)

for %%D in (c\bin c\bin-nostdlib cpp\bin rust\bin go\bin zig\bin) do (
    if not exist "%%D" mkdir "%%D"
)

echo Building C and C++...
clang -O2 c\main.c -o c\bin\hello-c.exe
if errorlevel 1 goto failed
clang++ -O2 cpp\main.cpp -o cpp\bin\hello-cpp.exe
if errorlevel 1 goto failed

echo Building Rust and Go...
rustc -C opt-level=2 rust\main.rs -o rust\bin\hello-rust.exe
if errorlevel 1 goto failed
go build -o go\bin\hello-go.exe go\main.go
if errorlevel 1 goto failed

echo Building Zig 0.16 ReleaseSafe and ReleaseSmall...
zig build-exe zig\main_016.zig -O ReleaseSafe -femit-bin=zig\bin\hello-zig.exe --cache-dir zig\.zig-cache --global-cache-dir zig\.zig-global-cache
if errorlevel 1 goto failed
zig build-exe zig\main_016.zig -O ReleaseSmall -femit-bin=zig\bin\hello-zig-small.exe --cache-dir zig\.zig-cache --global-cache-dir zig\.zig-global-cache
if errorlevel 1 goto failed

echo Building CRT-free C...
set "BASELINE_KERNEL32_LIB="
if defined WINDOWS_SDK_KERNEL32_LIB (
    if exist "%WINDOWS_SDK_KERNEL32_LIB%" set "BASELINE_KERNEL32_LIB=%WINDOWS_SDK_KERNEL32_LIB%"
)
if defined BASELINE_KERNEL32_LIB goto build_nostdlib
for /f "delims=" %%V in ('dir /b /ad /o-n "C:\Program Files (x86)\Windows Kits\10\Lib" 2^>nul') do (
    if exist "C:\Program Files (x86)\Windows Kits\10\Lib\%%V\um\x64\kernel32.Lib" (
        set "BASELINE_KERNEL32_LIB=C:\Program Files (x86)\Windows Kits\10\Lib\%%V\um\x64\kernel32.Lib"
        goto build_nostdlib
    )
)
echo Windows SDK kernel32.Lib not found. Set WINDOWS_SDK_KERNEL32_LIB to its x64 path.
goto failed

:build_nostdlib
clang -O2 -nostdlib -fuse-ld=lld c\main_nostdlib.c -o c\bin-nostdlib\hello-c-nostdlib.exe -Wl,/entry:mainCRTStartup -Wl,/subsystem:console "%BASELINE_KERNEL32_LIB%"
if errorlevel 1 goto failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File collect_disk_sizes.ps1
if errorlevel 1 goto failed

if /i "%~1"=="--run" (
    for %%E in (c\bin\hello-c.exe c\bin-nostdlib\hello-c-nostdlib.exe cpp\bin\hello-cpp.exe rust\bin\hello-rust.exe go\bin\hello-go.exe zig\bin\hello-zig.exe zig\bin\hello-zig-small.exe) do (
        echo Running %%E
        "%%E"
        if errorlevel 1 goto failed
    )
)
echo All seven hello-world baseline builds succeeded.
popd
exit /b 0

:failed
echo Hello-world baseline build failed.
popd
exit /b 1
