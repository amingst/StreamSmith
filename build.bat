@echo off

if not exist "libs\odin-imgui\imgui_windows_x64.lib" (
    echo Error: imgui_windows_x64.lib not found. Run setup.bat first.
    exit /b 1
)

if not exist "build" mkdir build

REM src/remote isn't imported by the app yet, so a plain `odin build src` never
REM looks at it. Type-check it on its own until main wires it up.
odin build src/remote -collection:libs=libs -vet -vet-shadowing -debug -build-mode:obj -out:build/remote_check.obj
if errorlevel 1 exit /b 1

odin build src -out:build/StreamSmith.exe -collection:libs=libs -vet -vet-shadowing -debug -resource:assets/icons/streamsmith.rc
