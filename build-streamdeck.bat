@echo off
setlocal

:: ============================================================
:: build-streamdeck.bat - builds the Stream Deck plugin exe
:: Usage: build-streamdeck.bat [--pack]
::   --pack also produces com.streamsmith.remote.streamDeckPlugin
::          (needs Elgato's CLI: npm install -g @elgato/cli)
:: ============================================================

set "PLUGIN_DIR=streamdeck\com.streamsmith.remote.sdPlugin"
set "OUT_DIR=%PLUGIN_DIR%\bin"

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

:: -subsystem:windows keeps a console window from appearing when the
:: Stream Deck app launches the plugin.
odin build streamdeck\src -out:"%OUT_DIR%\streamsmith-streamdeck.exe" -collection:libs=libs -vet -vet-shadowing -o:speed -subsystem:windows
if errorlevel 1 (
	echo Build failed.
	exit /b 1
)
echo Built %OUT_DIR%\streamsmith-streamdeck.exe

if /i not "%~1"=="--pack" goto :done

where streamdeck >nul 2>nul
if errorlevel 1 (
	echo The Elgato CLI is not on PATH. Install it with: npm install -g @elgato/cli
	exit /b 1
)

:: Called with a path rather than from inside streamdeck\: the CLI resolves
:: the plugin folder against the directory it was started in.
call streamdeck pack "%PLUGIN_DIR%" --force
if errorlevel 1 (
	echo Packing failed.
	exit /b 1
)
echo Packed com.streamsmith.remote.streamDeckPlugin

:done
endlocal
