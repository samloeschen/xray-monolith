@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
set "SOLUTION=%REPO_ROOT%src\engine-vs2022.sln"
set "OUTPUT_DIR=%REPO_ROOT%_build\_game\bin_dbg"
set "BUILD_ACTION=%BUILD_TARGET%"
if not defined BUILD_ACTION set "BUILD_ACTION=Build"

if not exist "%SOLUTION%" (
    echo ERROR: Solution not found: "%SOLUTION%"
    exit /b 1
)

findstr /C:"Modded Exes MT-TEST" "%REPO_ROOT%src\xrServerEntities\script_ini_file_script.cpp" >nul
if errorlevel 1 (
    echo ERROR: This checkout does not identify itself as the MT build.
    exit /b 1
)

set "MSBUILD=%MSBUILD_EXE%"
if defined MSBUILD set "MSBUILD=!MSBUILD:"=!"

if not defined MSBUILD (
    for /f "delims=" %%I in ('where msbuild.exe 2^>nul') do if not defined MSBUILD set "MSBUILD=%%~fI"
)

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" (
    set "VSWHERE="
    for /f "delims=" %%I in ('where vswhere.exe 2^>nul') do if not defined VSWHERE set "VSWHERE=%%~fI"
)

if not defined MSBUILD if defined VSWHERE (
    for /f "usebackq delims=" %%I in (`"!VSWHERE!" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do if not defined MSBUILD set "MSBUILD=%%~fI"
)

if not defined MSBUILD (
    echo ERROR: MSBuild was not found.
    echo Install Visual Studio Build Tools with the C++ workload, or set MSBUILD_EXE.
    exit /b 1
)

if not exist "!MSBUILD!" (
    echo ERROR: MSBuild does not exist at "!MSBUILD!".
    exit /b 1
)

echo Building MT executables with:
echo   "!MSBUILD!"

for %%C in (DX10 DX10-AVX DX11 DX11-AVX) do (
    call :build_configuration "%%C"
    if errorlevel 1 exit /b 1
)

for %%F in (AnomalyDX10.exe AnomalyDX10AVX.exe AnomalyDX11.exe AnomalyDX11AVX.exe) do (
    if not exist "%OUTPUT_DIR%\%%F" (
        echo ERROR: Expected build output is missing: "%OUTPUT_DIR%\%%F"
        exit /b 1
    )
)

echo MT executables are ready in "%OUTPUT_DIR%".
exit /b 0

:build_configuration
echo.
echo === %~1 ^| x64 ===
"!MSBUILD!" "%SOLUTION%" /nologo /m /verbosity:minimal /consoleloggerparameters:Summary /t:!BUILD_ACTION! /p:Configuration=%~1 /p:Platform=x64
if errorlevel 1 (
    echo ERROR: %~1 build failed.
    exit /b 1
)
exit /b 0
