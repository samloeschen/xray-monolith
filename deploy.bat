@echo off
setlocal EnableExtensions

set "REPO_ROOT=%~dp0"
set "BUILD_OUTPUT=%REPO_ROOT%_build\_game\bin_dbg"
set "SHADER_MANIFEST=%REPO_ROOT%packaging\shader-files.txt"

set "DEPLOY_ANOMALY=%ANOMALY_DIR%"
if not "%~1"=="" set "DEPLOY_ANOMALY=%~1"
if not defined DEPLOY_ANOMALY set "DEPLOY_ANOMALY=D:\anomaly"

set "DEPLOY_SHADER_MOD=%SHADER_MOD_DIR%"
if not "%~2"=="" set "DEPLOY_SHADER_MOD=%~2"
if not defined DEPLOY_SHADER_MOD set "DEPLOY_SHADER_MOD=D:\gamma\mods\Sam's Optimization Patches (Shaders)"

if not exist "%DEPLOY_ANOMALY%\bin\" (
    echo ERROR: Anomaly bin directory not found: "%DEPLOY_ANOMALY%\bin"
    echo Usage: deploy.bat [AnomalyRoot] [ShaderModRoot]
    exit /b 1
)

if not exist "%DEPLOY_SHADER_MOD%\" (
    echo ERROR: Shader mod directory not found: "%DEPLOY_SHADER_MOD%"
    echo Usage: deploy.bat [AnomalyRoot] [ShaderModRoot]
    exit /b 1
)

if not exist "%SHADER_MANIFEST%" (
    echo ERROR: Shader manifest not found: "%SHADER_MANIFEST%"
    exit /b 1
)

set "BUILD_TARGET=Build"
call "%REPO_ROOT%build-mt.bat"
if errorlevel 1 exit /b 1

echo.
echo Deploying MT executables to "%DEPLOY_ANOMALY%\bin"...
for %%F in (AnomalyDX10.exe AnomalyDX10AVX.exe AnomalyDX11.exe AnomalyDX11AVX.exe) do (
    copy /Y "%BUILD_OUTPUT%\%%F" "%DEPLOY_ANOMALY%\bin\%%F" >nul
    if errorlevel 1 (
        echo ERROR: Failed to deploy %%F.
        exit /b 1
    )
)

echo Deploying optimization shaders to "%DEPLOY_SHADER_MOD%"...
for /f "usebackq eol=# delims=" %%F in ("%SHADER_MANIFEST%") do (
    if not exist "%REPO_ROOT%%%F" (
        echo ERROR: Manifest file is missing: "%REPO_ROOT%%%F"
        exit /b 1
    )
    for %%D in ("%DEPLOY_SHADER_MOD%\%%F") do if not exist "%%~dpD" mkdir "%%~dpD"
    copy /Y "%REPO_ROOT%%%F" "%DEPLOY_SHADER_MOD%\%%F" >nul
    if errorlevel 1 (
        echo ERROR: Failed to deploy %%F.
        exit /b 1
    )
)

echo.
echo Deployment complete.
echo Delete the shader cache before launching the game.
exit /b 0
