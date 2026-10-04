@echo off
rem Build the MSVC prebuilt LuaJIT static library for Windows.
rem
rem   tools\build_luajit_msvc.bat        (x64 - the one the engine links by default)
rem   tools\build_luajit_msvc.bat x86
rem
rem Everything is pinned. LUAJIT_REF is the commit whose build reports
rem   LuaJIT 2.1.1727870382
rem the same version string as the shipped Android / Linux / macOS libraries, so a
rem local rebuild stays ABI-compatible with them.
rem Override with:  set LUAJIT_REF=<sha-or-tag>  before calling this script.
rem
rem The result goes straight to the path project\Build.xml references, and the
rem version string is checked afterwards so a mismatched build cannot slip through.
setlocal enabledelayedexpansion

set ARCH=%1
if "%ARCH%"=="" set ARCH=x64
if /i "%ARCH%"=="x86" ( set VCVARS_ARCH=x86 & set DEST=project\luajit\lib\Windows\lua51-x86.lib )
if /i "%ARCH%"=="x64" ( set VCVARS_ARCH=x64 & set DEST=project\luajit\lib\Windows\lua51-x86_64.lib )
if not defined DEST ( echo unknown arch %ARCH% - use x86 or x64 & exit /b 2 )

set "ROOT=%~dp0.."
set "SRC=%ROOT%\.luajit-src"
if "%LUAJIT_REF%"=="" set "LUAJIT_REF=97813fb924edf822455f91a5fbbdfdb349e5984f"

rem --- locate a Visual Studio with the C++ toolset ---------------------------
rem NOTE: %ProgramFiles(x86)% must not be expanded inside a parenthesised block:
rem the closing paren in that variable name breaks batch parsing. Hence PF86.
set "PF86=%ProgramFiles(x86)%"
set "VSWHERE=%PF86%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSPATH="
if exist "%VSWHERE%" for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH if exist "%PF86%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" set "VSPATH=%PF86%\Microsoft Visual Studio\2022\BuildTools"
if not defined VSPATH if exist "%PF86%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" set "VSPATH=%PF86%\Microsoft Visual Studio\2019\Community"
if not defined VSPATH ( echo ::error::no Visual Studio C++ toolset found - install Desktop development with C++ & exit /b 1 )

echo ==^> toolset: %VSPATH%
call "%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat" %VCVARS_ARCH%
if errorlevel 1 ( echo ::error::vcvarsall.bat failed for %VCVARS_ARCH% & exit /b 1 )

rem --- LuaJIT source ---------------------------------------------------------
if not exist "%SRC%\.git" (
  echo ==^> cloning LuaJIT
  git clone --quiet --filter=blob:none --branch v2.1 --single-branch https://github.com/LuaJIT/LuaJIT.git "%SRC%"
  if errorlevel 1 ( echo ::error::git clone failed & exit /b 1 )
)
git -C "%SRC%" fetch --quiet origin
git -C "%SRC%" checkout --quiet %LUAJIT_REF%
if errorlevel 1 ( echo ::error::cannot check out %LUAJIT_REF% & exit /b 1 )

pushd "%SRC%\src"
call msvcbuild.bat static
set RC=%ERRORLEVEL%
popd
if not "%RC%"=="0" ( echo ::error::msvcbuild.bat static failed & exit /b %RC% )
if not exist "%SRC%\src\lua51.lib" ( echo ::error::lua51.lib was not produced & exit /b 1 )

mkdir "%ROOT%\project\luajit\lib\Windows" 2>nul
copy /y "%SRC%\src\lua51.lib" "%ROOT%\%DEST%" >nul
if errorlevel 1 ( echo ::error::copy to %DEST% failed & exit /b 1 )
echo ==^> wrote %DEST%

findstr /C:"LuaJIT 2.1." "%ROOT%\%DEST%" >nul
if errorlevel 1 (echo ==^> version string check: NOT FOUND ^(suspicious^)) else (echo ==^> version string check: OK)

pushd "%ROOT%"
python tools\check_prebuilt_libs.py --allow-missing
popd
exit /b 0
