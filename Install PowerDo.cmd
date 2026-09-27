@echo off
title PowerDo Installer
color 0B
set "LAUNCHER="
where pwsh >nul 2>nul && set "LAUNCHER=pwsh"
if not defined LAUNCHER if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "LAUNCHER=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined LAUNCHER goto run
where powershell >nul 2>nul && set "LAUNCHER=powershell"
if defined LAUNCHER (
  echo.
  echo   [i] PowerShell 7 ^(pwsh^) not found - using Windows PowerShell
  echo       to run the installer. It will offer to install pwsh for you.
  echo.
)
if not defined LAUNCHER goto nops
:run
"%LAUNCHER%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PowerDo.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%~1"=="" exit /b %RC%
echo.
pause
exit /b %RC%
:nops
echo.
echo   [xx] no PowerShell found on this system.
echo.
pause
exit /b 1
