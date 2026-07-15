# Geogram

**Geogram is an off-grid-first messenger and app launcher.** It speaks several
networks at once — the internet, a [Reticulum](docs/reticulum-connections.md) overlay, the
[APRS](docs/aprs.md) network, and direct [Bluetooth LE](docs/ble.md) — and glues
them together so a message or a file reaches the other side over whatever path
is available. When there's no internet, it falls back to radio and Bluetooth;
when there is, it uses it. No accounts, no central server.

On top of that transport core, Geogram is a **launcher for "wapps"** —
sandboxed WebAssembly apps that render through a shared native UI. The flagship
wapp, **Chat**, is shown throughout this README as an example of what the
platform does.

<p align="center">
  <img src="docs/screenshots/01-launcher.png" width="240" alt="Geogram launcher">
  <img src="docs/screenshots/02-activity.png" width="240" alt="Chat: Activity feed">
  <img src="docs/screenshots/04-chat.png" width="240" alt="Chat: 1:1 with media">
</p>

---

## Download

Direct downloads of the latest stable build:

| Platform | Download |
|----------|----------|
| Linux (x64) | [Geogram for Linux (.tar.gz)](https://github.com/geograms/aurora/releases/latest/download/aurora-linux-x64.tar.gz) |
| Windows (x64) | [Geogram for Windows (installer)](https://github.com/geograms/aurora/releases/latest/download/aurora-windows-x64-setup.exe) |
| Android | [Geogram for Android (.apk)](https://github.com/geograms/aurora/releases/latest/download/aurora.apk) |

All releases (including betas) are on the
[releases page](https://github.com/geograms/aurora/releases). macOS builds from
source — see [Build & run](#build--run).

---

## What it does

- **Multi-transport messaging** — one message goes out over internet (APRS-IS),
  Bluetooth LE, or Reticulum/LXMF, and incoming messages are tagged with the
  path they arrived on (`NET`, `BLE`, `RET`/`RNS`, `RLY`).
- **Off-grid by design** — APRS over radio and connectionless BLE broadcast keep
  working with no internet at all. A phone with internet automatically
  **bridges** its BLE-only peers onto the Reticulum hubs, so an offline device
  stays reachable worldwide.
- **Decentralized identity** — every station has a Nostr keypair (secp256k1) and
  periodically announces its public key, enabling **signed** and
  **end-to-end-encrypted** 1:1 messages without any directory server.
- **Content-addressed files** — media and files are referenced by `sha256` hash,
  found through a Kademlia DHT over Reticulum, and re-seeded by every downloader.
- **Wapp platform** — install/run sandboxed WebAssembly apps (Chat, Reticulum,
  Circles, Player, Terminal, …) that share one native UI and the host's
  transports.
- **Cross-platform** — Linux, Windows, macOS, Android. In-app Update Center
  (stable / beta channels) for OTA updates.

---

## The Chat wapp — a tour

Geogram's main app is **Chat**: a full messaging station that puts an Activity
feed, 1:1 and group messaging, a live map, and a follow roster behind one panel.

### Launcher

![Launcher](docs/screenshots/01-launcher.png)

Wapps are grouped on the home screen; the red **Chat** tile opens the messenger.
The profile pill (top-left) carries your callsign and a deterministic identicon.

### Activity feed

![Activity](docs/screenshots/02-activity.png)

A public, Twitter-style stream of the people you follow. Posts carry text,
embedded media thumbnails, like / reply / save actions, a transport badge per
post, and a three-dot menu to **block** or **mute** an author.

### Messages — 1:1 and groups

![Messages](docs/screenshots/03-messages.png)

Direct chats and `#`-prefixed group channels in one list. `(global)` groups are
followed worldwide; local groups only within your map radius. Fresh installs are
seeded with global groups (`#DEV`, `#NEWS`, `#HELP`, …) and every contact gets a
generated identicon.

<p align="center">
  <img src="docs/screenshots/07-add-group.png" width="240" alt="Add a group">
  <img src="docs/screenshots/04-chat.png" width="240" alt="Chat with media">
</p>

Join a group from preset chips or a custom tag (left). Inside a chat (right),
messages have timestamps, file attachments, and inline content-addressed images;
1:1 DMs are encrypted to the recipient's key when known, and can be signed.

### Geochat — live map

![Geochat](docs/screenshots/05-geochat.png)

A live map of stations and geotagged messages around you. The range slider sets
your filter radius; pins cluster nearby beacons. Position, status, emergency and
timed beacons are composed and broadcast from here.

### Follows

![Follows](docs/screenshots/06-follows.png)

Manage who you follow and who follows you; following a callsign streams their
public Activity into your feed.

---

## How it reaches people

```
            ┌─────────────────────────────────────────────────────────┐
            │                     Geogram chat (wapps)                 │
            │   APRX message conventions  +  file: media references    │
            └───────────────┬───────────────────────┬─────────────────┘
                            │                       │
                 message transport          file transport / discovery
                 ┌──────────┴──────────┐    ┌────────┴───────────────┐
                 │  APRS-IS    BLE      │    │  Reticulum links        │
                 │  (TNC2)   (compact)  │    │  + DHT (find by hash)   │
                 │                      │    │  + relay (find by text) │
                 └──────────────────────┘    └────────┬───────────────┘
                                                      │
                                              ┌───────┴────────┐
                                              │  Reticulum RNS  │
                                              │ TCP/UDP/BLE/Auto│
                                              └─────────────────┘
```

- **Messages** ride APRS (internet APRS-IS or off-grid BLE) and Reticulum/LXMF.
- **Files** are *referenced* by content hash inside messages and *transferred*
  out of band over Reticulum, the DHT, a LAN, or BitTorrent.
- **Reticulum** is the transport that lets two devices on different networks
  reach each other; the **DHT** is the decentralized index that finds *who holds
  a file* with no central server. Hubs relay bytes only — they never see content.

The protocol/networking layers are documented with file/line pointers into the
code under [`docs/`](docs/README.md):
[reticulum-connections](docs/reticulum-connections.md), [aprs](docs/aprs.md),
[ble](docs/ble.md), [aprx](docs/aprx.md), [circles](docs/circles.md).

---

## Build & run

Geogram is a Flutter app; the Reticulum stack is a pure-Dart sibling package.

```sh
flutter pub get
flutter run -d linux        # or windows / macos
```

Android:

```sh
./launch-android.sh         # build + install on a connected device
```

The bundled wapps live in `assets/wapps/`. To rebuild a wapp from source, see
the [`geograms/wapps`](https://github.com/geograms/wapps) repository.

---

## Development

> **Build on the wapp layer, not the core engine — by default.** A wapp updates
> in place: users get it through the Wapp Store, or it ships as a small `.wapp` with
> no reinstall. Changing the **core engine means a whole new APK** the user must
> download and install (and on Android that is a signed-update dance, versionCode
> bumps, and a slow rollout — see [Validation](docs/validation.md)). So the default
> home for new functionality is a **wapp**. Touch the core engine **only when the
> feature genuinely cannot live in a wapp** — a new transport, a HAL primitive a wapp
> needs but can't express, a cross-cutting host service. When you find yourself about
> to add feature logic to the engine, stop and ask whether it belongs in a wapp
> instead; the answer is usually yes. Keep the host **generic** — app-specific logic
> (APRS/Chat conventions, social rules) lives in the wapp's C + GeoUI, never in
> `lib/`. Most changes should land in [`geograms/wapps`](https://github.com/geograms/wapps),
> not here.

These documents define how code is written and accepted in this repo. Read the
relevant one before touching that area — they are the conventions, not just notes.

- **[Validation](docs/validation.md)** — the acceptance bar: a task is done only
  after it is driven end-to-end on a connected Android phone with real taps and a
  screenshot proving it works from the user's perspective. Also: keep honest status
  messages flowing, and investigate a reported issue through the *whole* workflow
  rather than stopping at the first bug.
- **[Performance](docs/performance.md)** — how Aurora burns CPU/memory, what was
  fixed and how it was measured, and (§8) the rules for adding new work without
  regressing it: keep heavy work off the UI isolate, survive a suspended Android
  phone via the foreground service + native heartbeat, reuse the `BackgroundService`
  template, drive wapps on an interval via the event bus, and never trust the network
  — transfers must be resumable, idle links closed, and liveness swept on a tick.
- **[Notifications](docs/notifications.md)** — how any wapp or host code raises a
  notification, the severity/scope types, and how they escalate to system
  notifications on desktop and Android.
- **[Reusable services](docs/reusable.md)** — the shared host services (event bus,
  notifications, storage, …) a wapp or feature should build on instead of
  reinventing.
