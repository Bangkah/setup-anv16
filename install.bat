@echo off
setlocal EnableExtensions

set "BASE_DIR=%~dp0"
set "PS_SCRIPT=%BASE_DIR%install.ps1"

if not exist "%PS_SCRIPT%" (
  echo [ERROR] File "%PS_SCRIPT%" tidak ditemukan.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%PS_SCRIPT%""' -Verb RunAs"
if not "%errorlevel%"=="0" (
  echo [ERROR] Gagal menjalankan installer PowerShell.
  pause
  exit /b 1
)

exit /b 0
