@echo off
title TTYQ History Query - Keep This Window Open
powershell.exe -NoLogo -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-query.ps1"
pause
