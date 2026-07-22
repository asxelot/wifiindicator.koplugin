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
- **Non-blocking Wi-Fi connect** (Kobo & other wpa_supplicant devices, and
  Kindle). Stock KOReader connects synchronously in the UI thread, freezing
  the device for the duration (hardware bring-up, scan, association, DHCP on
  Kobo; the scan wait on Kindle). The bundled engine moves the blocking steps
  into subprocesses and 250 ms polls, so you can keep reading while Wi-Fi
  connects. No-op on other platforms.

All behaviors can be switched off individually under
**Menu → Network → Wi-Fi status icon**.

## Install

1. Download **`wifiindicator.koplugin.zip`** from the
   [latest release](https://github.com/asxelot/wifiindicator.koplugin/releases/latest)
   and unzip it. It expands to a correctly-named `wifiindicator.koplugin/`
   folder — no renaming needed.
2. Copy that folder into `koreader/plugins/` on your device.
3. Restart KOReader.

<details>
<summary>Install from source instead</summary>

`git clone` this repo (or **Code → Download ZIP** and unzip, then strip the
`-main` suffix so the folder ends in `.koplugin`). Only `main.lua`,
`nbwifi.lua` and `_meta.lua` are needed at runtime; copy the folder into
`koreader/plugins/`.
</details>

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

## Relation to koreader-nonblocking-wifi

The non-blocking connect engine is the bundled version of the
[koreader-nonblocking-wifi](https://github.com/asxelot/koreader-nonblocking-wifi)
user patch. If you have both installed, the user patch takes precedence and
the plugin's copy backs off automatically (they coordinate through
`NetworkMgr._nbwifi_installed`), so nothing breaks — but you only need one.
Field-tested on Kobo Libra Colour (MTK) and a lipc Kindle.

## License

GPL-3.0 — see [LICENSE](LICENSE).
