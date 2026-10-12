@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0measure_working_set.ps1" %*
exit /b %errorlevel%
