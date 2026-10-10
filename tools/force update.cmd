@echo off
rem Double-click to reinstall every CraftWerk app from its latest release, even if it's already current.
echo Reinstalling every CraftWerk app from its latest release.
echo Close all the Craft apps first; any that are open get skipped.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-craftwerk.ps1" -Apply -Force
echo.
pause
