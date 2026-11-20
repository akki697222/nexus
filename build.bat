@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

lua build.lua %*
if errorlevel 1 exit /b %errorlevel%

xcopy "..\ocelot\boot\*" "D:\Instances\1.21.1(6)\minecraft\saves\新規ワールド\opencomputers\b8933b46-5807-4756-9f60-a76edf12bdc4" /E /I /Y
if errorlevel 1 exit /b %errorlevel%

exit /b 0
