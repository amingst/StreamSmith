@echo off
REM Runs every package that has tests. Odin's test runner takes one package at
REM a time, so each gets its own line -- add new ones as they appear.
REM
REM -collection:libs matches build.bat: a test package that transitively
REM imports odin-imgui won't resolve without it.

setlocal
set FLAGS=-collection:libs=libs -vet -vet-shadowing -debug
set FAILED=0

echo === action ===
odin test src/action %FLAGS%
if errorlevel 1 set FAILED=1

echo === app ===
odin test src/app %FLAGS%
if errorlevel 1 set FAILED=1

echo === applog ===
odin test src/applog %FLAGS%
if errorlevel 1 set FAILED=1

echo === audio ===
odin test src/audio %FLAGS%
if errorlevel 1 set FAILED=1

echo === h264 ===
odin test libs/h264 %FLAGS%
if errorlevel 1 set FAILED=1

echo === flv ===
odin test libs/flv %FLAGS%
if errorlevel 1 set FAILED=1

echo === mf ===
odin test libs/mf %FLAGS%
if errorlevel 1 set FAILED=1

echo === remote ===
odin test src/remote %FLAGS%
if errorlevel 1 set FAILED=1

echo === protocol ===
odin test src/remote/protocol %FLAGS%
if errorlevel 1 set FAILED=1

echo === rtmp ===
odin test src/rtmp %FLAGS%
if errorlevel 1 set FAILED=1

echo === websocket ===
odin test libs/websocket %FLAGS%
if errorlevel 1 set FAILED=1

echo === streamdeck plugin ===
odin test streamdeck/src %FLAGS%
if errorlevel 1 set FAILED=1

if %FAILED%==1 (
    echo.
    echo === TESTS FAILED ===
    exit /b 1
)

echo.
echo === all tests passed ===
exit /b 0
