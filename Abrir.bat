@echo off
title Mercado PoE 1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0servidor.ps1"
pause
