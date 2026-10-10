@echo off
rem Opens the CraftWerk Manager window. -STA is needed for Windows Forms; the window is the only thing shown.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CraftWerk-Manager.ps1" %*
