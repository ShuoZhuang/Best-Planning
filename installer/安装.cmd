@echo off
rem ---------------------------------------------------------------------------
rem  Smart Planner - one-click MSIX installer (Windows)
rem
rem  Why this exists: the package is self-signed, so Windows refuses to install
rem  it until the signing certificate is trusted. Doing that by hand means
rem  walking through the certificate wizard (Local Machine -> Trusted People).
rem  This launcher just runs install-planner.ps1, which does those steps and
rem  then installs or upgrades the app. It will ask for administrator rights
rem  (one UAC prompt).
rem
rem  This file is intentionally ASCII-only: a .cmd is read with the OEM code
rem  page, and non-ASCII text here would show up as mojibake on some machines.
rem  All Chinese messages live in install-planner.ps1 (saved as UTF-8 with BOM).
rem ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0install-planner.ps1"
if not exist "%SCRIPT%" (
  echo.
  echo ERROR: install-planner.ps1 was not found next to this file.
  echo        Please extract the WHOLE folder, not a single file.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
