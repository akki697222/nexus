@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

lua build.lua %*
if errorlevel 1 exit /b %errorlevel%

set "OCSAVE=D:\Instances\1.21.1(6)\minecraft\saves\新規ワールド\opencomputers"

rem development disk: root/ and the plain kernel
xcopy "..\ocelot\boot\*" "%OCSAVE%\b8933b46-5807-4756-9f60-a76edf12bdc4" /E /I /Y
if errorlevel 1 exit /b %errorlevel%

rem image disk: the zlib boot image and its loader; /boot/config.lua and
rem the rest of the disk are kept
set "IMGDISK=%OCSAVE%\4f2bf821-7f7e-4434-b18a-272d4b70fc7c"
if not exist "%IMGDISK%\boot" mkdir "%IMGDISK%\boot"
copy /Y "..\ocelot\nexusos-zlib\boot\nexusos" "%IMGDISK%\boot\nexusos" >nul
if errorlevel 1 exit /b %errorlevel%
copy /Y "..\ocelot\nexusos-zlib\init.lua" "%IMGDISK%\init.lua" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist "%IMGDISK%\boot\config.lua" copy /Y "root\boot\config.lua" "%IMGDISK%\boot\config.lua" >nul
echo Deployed zlib image to %IMGDISK%

exit /b 0
