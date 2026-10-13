@echo off
rem Per-user install: copies MagicWand, starts it with Windows, adds a Start menu entry. No admin needed.
rem Uninstall: Install.cmd /uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
