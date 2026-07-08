# WifiIndicator — quiet Wi-Fi status for KOReader

A KOReader plugin that stops Wi-Fi connection popups from interrupting your
reading and shows unobtrusive status icons instead.

Stock KOReader announces every step of its Wi-Fi lifecycle with an
`InfoMessage` popup over the page you're reading — *"Scanning for
networks…"*, *"Connecting to network X…"*, *"Connection failed"* — which is
especially noisy on devices that restore Wi-Fi after every wake from sleep
(e.g. Kindles with auto-restore enabled).

## What it does

- **Suppresses Wi-Fi popups.** The connection lifecycle messages from
  `NetworkMgr` (scanning, connecting, connected, failed, backend errors,
  Wi-Fi on/off) never appear. Matching is done against the exact source
  strings resolved through gettext, so it works in any UI language.
- **Corner toast instead.** A small transient Wi-Fi icon appears in the
  top-left corner for 3 seconds on connect/disconnect — same timeout as the
  popups it replaces, transparent to input.
- **Menu-bar status icon.** A Wi-Fi icon sits in the drop-down menu's footer,
  left of the clock and battery: full waves = connected, half = Wi-Fi on but
  not connected, empty = off. **Tap it to toggle Wi-Fi** (broadcasts the same
  `ToggleWifi` event as the gesture action).

All three behaviors can be switched off individually under
**Menu → Network → Wi-Fi status icon**.

## Install

Copy the `wifiindicator.koplugin` folder into `koreader/plugins/` on your
device (only `main.lua` and `_meta.lua` are needed) and restart KOReader.

## How it works

KOReader has no hook for filtering another module's popups, so the plugin
wraps two things at load time (each patch applied once, guarded against the
plugin's dual FileManager/ReaderUI instantiation):

- `UIManager.show` — drops `InfoMessage`s whose text matches a known
  Wi-Fi lifecycle string, optionally showing the corner toast instead.
- `TouchMenu.init` / `TouchMenu.updateItems` — injects an `IconButton` into
  the menu footer's device-info group and refreshes its state from
  `NetworkMgr:isConnected()` / `isWifiOn()` on every menu update.

### Caveat

Popup suppression matches KOReader's **source strings**. If a KOReader
release changes or adds Wi-Fi popup wording, those popups will show again
until the `INTERCEPTED_MESSAGES` list in `main.lua` is updated — everything
else keeps working.

## Tests

A self-contained harness stubs the KOReader modules and exercises the real
plugin — popup filtering, icon injection, state mapping, tap-to-toggle, and
settings. Run it from the repo root with LuaJIT (or any Lua 5.1):

```sh
luajit test/test_main.lua main.lua
```

## Device still locks up while connecting?

This plugin quiets the *popups*, but on Kobo and other devices where
KOReader drives `wpa_supplicant` itself, the whole connect sequence runs
synchronously in the UI thread — the device freezes until the connection
is established, popups or not. For that there's a companion user patch,
[koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi),
which moves the scan, authentication wait, and DHCP off the UI thread so
you can keep reading while Wi-Fi connects. (Kindles don't need it — the
OS already connects in the background there.)

## License

GPL-3.0 — see [LICENSE](LICENSE).
