## Quick Start

```
git clone --recurse-submodules https://github.com/amingst/streamsmith.git
cd streamsmith
setup.bat
build.bat
```

## Prerequisites

The following tools must be installed and available on your PATH before running `setup.bat`.

### Git

Required for cloning and initializing submodules.

### Odin Lang

Install the Odin language and add to PATH.
https://odin-lang.org/docs/install/

### Premake5

Required for generating the imgui build files. Download and add to PATH.
https://premake.github.io/download

### Python 3.3+

Required by Dear Bindings to generate C bindings for imgui during setup.

### Visual Studio with C++ workload

`setup.bat` requires a Visual Studio installation (Community, Professional, or Build Tools) with the **Desktop development with C++** workload. This provides MSBuild and the MSVC compiler. Supported versions: VS 2017, 2019, 2022, and 2026. The script auto-detects the latest installed version via `vswhere`.

### Node.js and the Elgato CLI (optional)

Only needed to package the Stream Deck plugin into a `.streamDeckPlugin` file. The
CLI also validates the plugin as it packs, so it is the only packaging path.

```
npm install -g @elgato/cli
```

Users installing the plugin never need Node; this is a build-machine tool.

### Stream Deck 6.9 or newer (optional)

Needed to run the Stream Deck plugin. The manifest declares `Software.MinimumVersion`
6.9, which is the minimum for SDK 3 and Marketplace DRM. An older Stream Deck app
refuses to load the plugin and logs `Plugin conflict: 'com.streamsmith.remote'`
instead of showing its actions.

### D3D11 Debug Layer (optional)

The D3D11 debug layer requires the "Graphics Tools" optional Windows feature. Install via Settings > Apps > Optional features > Add a feature > Graphics Tools.

## Building

### `setup.bat`

Run once to initialize git submodules, generate imgui build files with premake5, and compile the imgui static library (`imgui_windows_x64.lib`) with MSBuild. The script is idempotent -- if the library already exists, it exits early.

What it does:
1. Validates prerequisites (git, premake5, python, MSBuild)
2. Initializes git submodules (`libs/odin-imgui`)
3. Runs premake5 to generate a Visual Studio solution for imgui (with win32, dx11, glfw, and opengl3 backends)
4. Builds the solution with MSBuild (Release, x64)
5. Verifies `libs/odin-imgui/imgui_windows_x64.lib` was produced

To force a clean rebuild of the imgui library:

```
setup.bat --force
```

### `build.bat`

Compiles the project with the Odin compiler:

```
odin build src -out:build/StreamSmith.exe -collection:libs=libs -vet -vet-shadowing -debug
```

### `test.bat`

Runs every package that has tests. Odin's test runner takes one package at a time,
so each gets its own line in the script -- add new ones there as they appear.

### `build-streamdeck.bat`

Builds the Stream Deck plugin executable into
`streamdeck/com.streamsmith.remote.sdPlugin/bin/`:

```
build-streamdeck.bat
```

Add `--pack` to also produce `com.streamsmith.remote.streamDeckPlugin` in the repo
root, which installs by double-clicking and is what CI attaches to a release:

```
build-streamdeck.bat --pack
```

The exe is built with `-subsystem:windows`, so no console window appears when the
Stream Deck app launches it. The Stream Deck app holds the exe open while the plugin
is running, so stop it first if the build reports that it cannot write the file:

```
streamdeck stop com.streamsmith.remote
```

## Stream Deck plugin

StreamSmith exposes a local WebSocket API (see [docs/remote-protocol.md](docs/remote-protocol.md)),
and the plugin in [streamdeck/](streamdeck/) sits between it and the Stream Deck app:

```
Stream Deck app <--ws--> streamsmith-streamdeck.exe <--ws--> StreamSmith (127.0.0.1:4460)
```

It is a native Odin plugin -- no Node SDK -- and shares `libs/websocket` and
`src/remote/protocol` with the app, so the wire format cannot drift between them.
[streamdeck/README.md](streamdeck/README.md) covers the actions, the settings the
property inspector stores, and the pre-release checklist.

### Remote control settings

Remote control is app-wide, not per show, and lives in `app.json`. Settings ->
Remote has an enable switch, the port (default **4460**) and an allowed-origins list
for browser clients. The tab shows whether the server is listening; if the port is
taken, StreamSmith logs it and carries on without remote control.

### Running the plugin from this repo

```
streamdeck dev
streamdeck link streamdeck/com.streamsmith.remote.sdPlugin
```

`dev` enables developer mode once; `link` points the Stream Deck app at the folder in
this repo, so a rebuild is picked up without reinstalling. After that, the loop for
each change is:

```
build-streamdeck.bat
streamdeck restart com.streamsmith.remote
```

The plugin's actions then appear under the **StreamSmith** category in the Stream
Deck app. It logs to `%APPDATA%\StreamSmith\streamdeck\plugin.log` (never inside the
plugin folder, which Marketplace DRM makes immutable), and `streamdeck validate
streamdeck/com.streamsmith.remote.sdPlugin` re-runs the manifest checks on their own.

## Packages

### odin-imgui

https://github.com/Capati/odin-imgui
