@echo off
setlocal
title CoexFix - Respaldo y Restauracion
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0CoexFix-Respaldo.ps1"

if not exist "%PSEXE%" (
  echo.
  echo   ERROR: no se encuentra PowerShell en:
  echo   %PSEXE%
  echo.
  pause
  exit /b 1
)

if not exist "%SCRIPT%" (
  echo.
  echo   ERROR: falta el archivo CoexFix-Respaldo.ps1
  echo.
  echo   Los DOS archivos tienen que estar en la misma carpeta:
  echo     - CoexFix-Respaldo.bat
  echo     - CoexFix-Respaldo.ps1
  echo.
  echo   Carpeta actual: %~dp0
  echo.
  pause
  exit /b 1
)

if /i "%~1"=="/elevado" goto :correr
"%SystemRoot%\System32\net.exe" session >nul 2>&1
if not errorlevel 1 goto :correr
echo.
echo   Solicitando permisos de administrador...
"%PSEXE%" -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevado' -Verb RunAs" >nul 2>&1
if errorlevel 1 goto :correr
exit /b

:correr
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
pause
