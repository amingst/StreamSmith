# StreamSmith Stream Deck plugin

A native Odin plugin: the Stream Deck app launches `streamsmith-streamdeck.exe`,
which holds two WebSocket connections — one to the Stream Deck app, one to
StreamSmith's remote API (see [../docs/remote-protocol.md](../docs/remote-protocol.md)).

```
Stream Deck app ◄──ws──► streamsmith-streamdeck.exe ◄──ws──► StreamSmith (127.0.0.1:4460)
      ▲
      └── settings page (pi/inspector.html, runs inside the Stream Deck app)
```

There is no Node SDK involved; the plugin speaks the Stream Deck protocol
itself and shares `libs/websocket` and `src/remote/protocol` with the app, so
the wire format can't drift between the two.

## Layout

```
src/                                  the plugin exe
  main.odin      argument parsing, startup, the single event loop
  deck.odin      Stream Deck protocol: register, events in, commands out
  link.odin      StreamSmith connection, local snapshot, reconnect backoff
  actions.odin   per-action key handling and button appearance
  log.odin       %APPDATA%\StreamSmith\streamdeck\plugin.log
com.streamsmith.remote.sdPlugin/
  manifest.json
  bin/           build output (gitignored)
  pi/            settings page: one HTML file and one JS file
  images/        key, action, category and plugin images (committed)
assets/generate_images.py             regenerates images/ from the app's icon font
```

## Actions

| Action | Settings | Press | Button state |
|---|---|---|---|
| Switch Scene | scene | `scene.set` | State 1 when it is the live scene |
| Toggle Streaming | — | `streaming.toggle` | State 1 while live |
| Toggle Recording | — | `recording.toggle` | State 1 while recording, title "Saving" while finalizing |
| Toggle Mute | audio source | `audio.toggleMute` | State 1 while muted |
| Volume Up / Down | audio source, step, direction | `audio.setVolume` (clamped) | Title shows the volume percentage |
| Toggle Source | scene + source | `source.toggleVisible` | State 1 while hidden |

Settings store **ids**, so renaming a scene or source doesn't break a button.
A button whose id is gone (deleted, or a different show loaded) shows `?` and
raises an alert when pressed. Button state always comes from StreamSmith's
events, never from guessing after a press.

While StreamSmith is closed, buttons show "Offline" and presses raise an alert;
the plugin retries with a 1 s → 10 s backoff. If the protocol versions don't
match, buttons show "Update plugin" and it stops retrying.

## Building

```
build-streamdeck.bat            builds the exe into com.streamsmith.remote.sdPlugin\bin
build-streamdeck.bat --pack     also packs com.streamsmith.remote.streamDeckPlugin
```

Packing uses Elgato's CLI (`npm install -g @elgato/cli`), which validates the
plugin as it packs, so it is the only packaging path. Node is needed on the
build machine only, never on a user's machine. CI builds and packs on every
tagged release and attaches the result next to the app.

Tests: `odin test streamdeck/src -collection:libs=libs` (also part of `test.bat`).

## Development loop

1. `streamdeck link com.streamsmith.remote.sdPlugin` once, so the Stream Deck
   app picks the folder up from the repo.
2. `build-streamdeck.bat`
3. `streamdeck restart com.streamsmith.remote`

Logs: `%APPDATA%\StreamSmith\streamdeck\plugin.log` (one rollover at 1 MB).
Never write inside the plugin folder — Marketplace DRM encrypts those files,
and the manifest is not readable at runtime, which is why the action UUIDs are
compiled into `actions.odin`.

## Manual checklist before a release

- [ ] Each action against a running StreamSmith.
- [ ] Changes made in the app's UI update the buttons.
- [ ] Quitting StreamSmith shows the offline state; restarting reconnects.
- [ ] Switching shows marks stale buttons with `?`.
- [ ] Two Stream Deck profiles open at once.
- [ ] The port field in the settings page, against a non-default port.
- [ ] A DRM build from Maker Console ("Publish after review" unchecked), since
      DRM only applies after upload.
