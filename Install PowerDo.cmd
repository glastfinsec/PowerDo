@echo off
title PowerDo Installer
color 0B
where pwsh >nul 2>nul
if errorlevel 1 (
  echo.
  echo   [xx] PowerShell 7 ^(pwsh^) is required.
  echo        install:  winget install Microsoft.PowerShell
  echo.
  pause
  exit /b 1
)
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PowerDo.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%~1"=="" exit /b %RC%
echo.
pause
exit /b %RC%
