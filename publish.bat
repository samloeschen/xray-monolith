@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
set "BUILD_OUTPUT=%REPO_ROOT%_build\_game\bin_dbg"
set "SHADER_MANIFEST=%REPO_ROOT%packaging\shader-files.txt"
set "INSTALL_SOURCE=%REPO_ROOT%packaging\INSTALL.txt"

set "VERSION=%~1"
if not defined VERSION set "VERSION=%PUBLISH_VERSION%"
if not defined VERSION (
    for /f "delims=" %%I in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyy.MM.dd"') do set "VERSION=%%I"
    for /f "delims=" %%I in ('git -C "%REPO_ROOT%" rev-parse --short^=8 HEAD 2^>nul') do set "GIT_REV=%%I"
    if defined GIT_REV set "VERSION=!VERSION!-!GIT_REV!"
)

set "PUBLISH_OUTPUT=%~2"
if not defined PUBLISH_OUTPUT set "PUBLISH_OUTPUT=%PUBLISH_DIR%"
if not defined PUBLISH_OUTPUT set "PUBLISH_OUTPUT=%REPO_ROOT%_build\publish"

set "STAGE=%PUBLISH_OUTPUT%\stage"
set "SHADER_STAGE=%STAGE%\shaders"
set "EXE_STAGE=%STAGE%\executables"
set "BUNDLE_STAGE=%STAGE%\bundle"
set "SHADER_ZIP=%BUNDLE_STAGE%\Sam-Optimization-Patches-Shaders.zip"
set "EXE_ZIP=%BUNDLE_STAGE%\Sam-Optimization-Patches-MT-Executables.zip"
set "PACKAGE_ZIP=%PUBLISH_OUTPUT%\Sam-Optimization-Patches-MT_!VERSION!.zip"

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: Windows PowerShell is required to create ZIP archives.
    exit /b 1
)

if not exist "%SHADER_MANIFEST%" (
    echo ERROR: Shader manifest not found: "%SHADER_MANIFEST%"
    exit /b 1
)

if not exist "%INSTALL_SOURCE%" (
    echo ERROR: Installation instructions not found: "%INSTALL_SOURCE%"
    exit /b 1
)

set "BUILD_TARGET=Rebuild"
call "%REPO_ROOT%build-mt.bat"
if errorlevel 1 exit /b 1

if exist "%STAGE%\" rmdir /S /Q "%STAGE%"
mkdir "%SHADER_STAGE%" || exit /b 1
mkdir "%EXE_STAGE%\Anomaly\bin" || exit /b 1
mkdir "%BUNDLE_STAGE%" || exit /b 1

for /f "usebackq eol=# delims=" %%F in ("%SHADER_MANIFEST%") do (
    if not exist "%REPO_ROOT%%%F" (
        echo ERROR: Manifest file is missing: "%REPO_ROOT%%%F"
        exit /b 1
    )
    for %%D in ("%SHADER_STAGE%\%%F") do if not exist "%%~dpD" mkdir "%%~dpD"
    copy /Y "%REPO_ROOT%%%F" "%SHADER_STAGE%\%%F" >nul
    if errorlevel 1 exit /b 1
)

for %%F in (AnomalyDX10.exe AnomalyDX10AVX.exe AnomalyDX11.exe AnomalyDX11AVX.exe) do (
    if not exist "%BUILD_OUTPUT%\%%F" (
        echo ERROR: Build output is missing: "%BUILD_OUTPUT%\%%F"
        exit /b 1
    )
    copy /Y "%BUILD_OUTPUT%\%%F" "%EXE_STAGE%\Anomaly\bin\%%F" >nul
    if errorlevel 1 exit /b 1
)

copy /Y "%INSTALL_SOURCE%" "%BUNDLE_STAGE%\INSTALL.txt" >nul || exit /b 1

echo Creating shader mod archive...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Compress-Archive -LiteralPath (Join-Path $env:SHADER_STAGE 'gamedata') -DestinationPath $env:SHADER_ZIP -CompressionLevel Optimal -Force"
if errorlevel 1 exit /b 1

echo Creating MT executable archive...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Compress-Archive -LiteralPath (Join-Path $env:EXE_STAGE 'Anomaly') -DestinationPath $env:EXE_ZIP -CompressionLevel Optimal -Force"
if errorlevel 1 exit /b 1

if exist "%PACKAGE_ZIP%" del /Q "%PACKAGE_ZIP%"
echo Creating release bundle...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; Compress-Archive -Path (Join-Path $env:BUNDLE_STAGE '*') -DestinationPath $env:PACKAGE_ZIP -CompressionLevel Optimal -Force"
if errorlevel 1 exit /b 1

rmdir /S /Q "%STAGE%"

echo.
echo Published:
echo   "%PACKAGE_ZIP%"
exit /b 0
