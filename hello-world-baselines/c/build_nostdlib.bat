@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%" || exit /b 1

set "RUN_AFTER_BUILD=0"
if /I "%~1"=="--run" set "RUN_AFTER_BUILD=1"

where clang >nul 2>nul
if errorlevel 1 (
  echo error: clang not found in PATH
  exit /b 1
)

set "KERNEL32_LIB="
if defined WINDOWS_SDK_KERNEL32_LIB (
  if exist "%WINDOWS_SDK_KERNEL32_LIB%" (
    set "KERNEL32_LIB=%WINDOWS_SDK_KERNEL32_LIB%"
  )
)

if not defined KERNEL32_LIB (
  for /f "delims=" %%I in ('dir /b /ad /o-n "C:\Program Files (x86)\Windows Kits\10\Lib" 2^>nul') do (
    if exist "C:\Program Files (x86)\Windows Kits\10\Lib\%%I\um\x64\kernel32.Lib" (
      set "KERNEL32_LIB=C:\Program Files (x86)\Windows Kits\10\Lib\%%I\um\x64\kernel32.Lib"
      goto found_kernel32
    )
  )
)

:found_kernel32
if not defined KERNEL32_LIB (
  echo error: kernel32.Lib not found under Windows Kits 10 SDK paths
  echo error: set WINDOWS_SDK_KERNEL32_LIB to an explicit x64 kernel32.Lib path
  exit /b 1
)

if not exist "bin-nostdlib" mkdir "bin-nostdlib"
del /q "bin-nostdlib\hello-c-nostdlib.exe" >nul 2>nul

echo sdk lib: "%KERNEL32_LIB%"
echo building: "bin-nostdlib\hello-c-nostdlib.exe"

clang -nostdlib -fuse-ld=lld -o "bin-nostdlib\hello-c-nostdlib.exe" "main_nostdlib.c" -Wl,/entry:mainCRTStartup -Wl,/subsystem:console "%KERNEL32_LIB%"
if errorlevel 1 exit /b 1

for %%F in ("bin-nostdlib\hello-c-nostdlib.exe") do echo size bytes: %%~zF

if "%RUN_AFTER_BUILD%"=="1" (
  echo running: "bin-nostdlib\hello-c-nostdlib.exe"
  "bin-nostdlib\hello-c-nostdlib.exe"
)
