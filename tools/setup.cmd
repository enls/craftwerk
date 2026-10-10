@echo off
rem Double-click to turn on weekly updates and register the Craft apps with Windows on this PC.
rem Works on a fresh PC, where Windows blocks .ps1 scripts by default: this launcher allows
rem this one run only and doesn't change any system setting.
rem   setup.cmd -Remove        turns it all off again
rem   setup.cmd -Day Wednesday -At 7pm
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-schedule.ps1" %*
echo.
pause
