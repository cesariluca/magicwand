@echo off
rem Runs MagicWand in place, with no console window.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0MagicWand.ps1"
