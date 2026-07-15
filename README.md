# Geogram

**Geogram is an off-grid-first messenger and app launcher.** It speaks several
networks at once — the internet, a [Reticulum](docs/reticulum-connections.md)
overlay, and direct [Bluetooth LE](docs/ble.md) — and glues them together so a
message or a file reaches the other side over whatever path is available. When
there's no internet, it falls back to a Bluetooth street mesh and long-range
radio; when there is, it uses it. **No accounts, no phone number, no central
server.**

On top of that transport core, Geogram is a **launcher for "wapps"** — sandboxed
WebAssembly apps that render through one shared native UI and ride the host's
transports. This README tours the four flagship wapps: **Chat**, **Social**,
**Reticulum**, and **Torrents**.

<p align="center">
  <img src="docs/screenshots/launcher.png" width="240" alt="Geogram launcher">
  <img src="docs/screenshots/chat-groups.png" width="240" alt="Chat: group channels">
  <img src="docs/screenshots/reticulum-graph.png" width="240" alt="Reticulum: live node graph">
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

- **Multi-transport by default** — one message goes out over the internet,
  Bluetooth LE, or [Reticulum](docs/reticulum-connections.md)/LXMF, and incoming
  messages are tagged with the path they arrived on (`NET`, `BLE`, `RET`/`RNS`,
  `RLY`). First path to arrive wins; the rest are de-duplicated.
- **Off-grid by design** — a [Bluetooth street mesh](docs/mesh.md) carries
  messages phone-to-phone with no infrastructure, and low-power **LoRa** dongles
  extend it over kilometres. A phone that *does* have internet automatically
  **bridges** its Bluetooth-only and LoRa neighbours onto the worldwide Reticulum
  network — so an offline device stays reachable across the planet.
- **Your device is the server** — there is no backend. Every phone stores, serves
  and re-seeds its own data. Identity, messages, files and social posts live on
  the devices that create them; the network is just the wire between them.
- **Decentralized identity** — every station has a Nostr keypair (secp256k1) and
  periodically announces its public key, enabling **signed** and
  **end-to-end-encrypted** messages with no directory server. Your private key
  never leaves the device (and is backed up under an emoji passphrase).
- **Content-addressed files** — media and files are referenced by `sha256`,
  located through a Kademlia **DHT over Reticulum**, and re-seeded by every
  downloader.
- **Cross-platform** — Linux, Windows, macOS, Android. In-app Update Center
  (stable / beta channels) for OTA updates.

---

## The wapps

Wapps are sandboxed WebAssembly apps that share Geogram's native UI and
transports. All app-specific logic lives in the wapp, so it updates on its own
without a new install. Four flagship wapps ship in the box.

### 💬 Chat — off-grid messaging

<p align="center">
  <img src="docs/screenshots/chat-groups.png" width="260" alt="Chat: group channels with transport badges">
</p>

Encrypted messages to anyone nearby over Bluetooth, or across the world over
Reticulum. Group channels (`#DEV`, `#NEWS`, `#HELP`, …) are `(global)` — followed
worldwide — or local, seen only within your map radius. 1:1 chats are
**end-to-end encrypted** to the recipient's key and **signed**, so they can't be
forged. The app bar shows which transports are live right now (`RET`, `BLE`), and
three tabs put a **Geochat** live map of nearby stations and a **Follows** roster
behind the same panel. Messages ride the Bluetooth mesh and Reticulum/LXMF
interchangeably.

### 🟣 Social — a decentralized feed

<p align="center">
  <img src="docs/screenshots/social-feed.png" width="260" alt="Social: All / Following / Saved feed with composer">
</p>

A NOSTR-style public feed. Post short notes with media, follow people by their
key, like/reply, and read three lanes — **All** (a global firehose gathered from
the relays your device can reach), **Following** (only people you follow), and
**Saved**. Posts are `kind-1` notes and profiles are `kind-0`, distributed over
Reticulum and fetched **directly from the author** for people you follow — there
is no feed server curating what you see. Everything you publish is signed with
your own key.

### 🛰️ Reticulum — see the mesh

<p align="center">
  <img src="docs/screenshots/reticulum-graph.png" width="260" alt="Reticulum: native node radar with peers, hubs, LoRa/Radio">
</p>

A native, off-thread visualization of the Reticulum network as your device hears
it: a live radar of **peers**, **hubs** and fellow **geograms**, with **LoRa**
and **Radio** interface counters along the bottom. Filter by network, browse the
reachable devices (each with its callsign and public key), send an **LXMF direct
message** to any of them, and even browse **NomadNet** node pages over the mesh.
It is an observed-only map — nothing here is a central directory; it is simply
what announces have reached this node.

### ⬇️ Torrents — folders that live on the mesh

<p align="center">
  <img src="docs/screenshots/torrents-list.png" width="240" alt="Torrents: library list">
  <img src="docs/screenshots/torrents-info.png" width="240" alt="Torrents: listing / info page">
  <img src="docs/screenshots/torrents-popularity.png" width="240" alt="Torrents: popularity over months">
</p>

A torrent client whose unit of sharing is a **folder**, addressed by a key
(`ntorrent1…`) rather than a fixed content hash — so the publisher can change the
contents and the link never breaks. Files inside stay `sha256`-addressed and
[content-verified](docs/torrents.md). Download a torrent and its files become
**real files on disk** that your device then **seeds for others**; pin it to keep
a full copy. Each listing carries a title, category, tags, cover art and a
favicon.

The Info page shows the folder's total size, a **cached seeder count** ("others
holding this now"), and a full **Popularity** panel — a native chart of seeders
and unique leechers per month, kept **on your device only**, never in the folder.
Because a folder is dynamic, a **Get updates** toggle lets a follower **freeze a
static copy** and stop pulling the publisher's changes. Share a torrent by link
or **QR code** (scanning is Android-only); the publisher's identity is **kept out
of the link unless you opt in** — an unsigned name is a phishing surface.

> Other bundled wapps include **Messages** (one unified encrypted NOSTR inbox),
> **Circles** (private group chat with rotating shared keys), a media **Player**,
> and the **Wapp Store**.

---

## Indexers, archivers, and true decentralization

There is no server anywhere. The network is made only of user devices, and a
device can volunteer for two extra roles:

- **Indexers** are the mesh's trackers. A holder publishes a **provider record**
  — "this destination holds folder *F* / file *sha*" — and indexers keep those
  pointers and answer text search, so a downloader can find *who has* something
  with no central catalog. Indexers store pointers, never the content.
- **Archivers** keep the bytes alive. They accept store-and-forward deposits and
  **mirror** followed folders, so content stays reachable even while its original
  owner is offline. Any downloader is already a partial archiver: it re-seeds what
  it fetched.

Put together, **every user's device is its own hosting server.** Your posts, your
files and your torrents are served by your phone and by whoever chose to mirror
them — not by a company. Take the whole rest of the network away and your device
still holds, serves and verifies its own data.

---

## Privacy

Reticulum makes casual, at-scale surveillance structurally hard:

- **No IP addresses.** Reticulum addresses are 16-byte **destination hashes**,
  never IPs. The copyright-troll / mass-scrape model — collect IPs from a swarm,
  mail threats — simply has nothing to collect.
- **Everything is encrypted.** Links are end-to-end encrypted with forward
  secrecy. **Hubs and relays route bytes only — they never see content.** 1:1
  messages are encrypted to the recipient's key; groups use rotating shared keys.
- **Pseudonymous keys, not people.** Identities are Nostr keypairs. A torrent's
  folder key is separate from your personal identity, and the publisher's `npub`
  is left out of a shared link by default — so a listing need not be attributable
  to a person.
- **Honest about the limits.** The unavoidable exposure in any swarm is the
  *who-has* map (provider records). Reticulum keeps that pseudonymous rather than
  tied to an IP, but it is not anonymity against an adversary who joins the mesh
  to correlate. See [`docs/torrents.md`](docs/torrents.md) for the full picture
  and the roadmap (ephemeral per-folder serving destinations, relay serving).

---

## How it reaches people

```
        ┌──────────────────────────────────────────────────────────┐
        │            Wapps  (Chat · Social · Reticulum · Torrents)  │
        └───────────────┬──────────────────────────┬───────────────┘
                        │                          │
              message transport            file transport / discovery
        ┌───────────────┴───────────┐    ┌─────────┴────────────────┐
        │  Reticulum / LXMF         │    │  Reticulum links          │
        │  Bluetooth mesh + LoRa    │    │  + DHT   (find by hash)   │
        │  internet                 │    │  + Indexers (find by text)│
        └───────────────┬───────────┘    └─────────┬────────────────┘
                        │                          │
                        └────────────┬─────────────┘
                              ┌──────┴───────────┐
                              │   Reticulum RNS   │
                              │ TCP/UDP/BLE/LoRa  │
                              └───────────────────┘
```

- **Messages** ride the Bluetooth mesh, LoRa, the internet, and Reticulum/LXMF —
  whichever is up.
- **Files** are *referenced* by content hash inside messages and *transferred*
  out of band over Reticulum, the DHT, a LAN, or BitTorrent.
- **Reticulum** is the transport that lets two devices on different networks reach
  each other; the **DHT** and **Indexers** are the decentralized indexes that find
  *who holds* a file with no central server.

The protocol/networking layers are documented with file/line pointers into the
code under [`docs/`](docs/README.md):
[reticulum-connections](docs/reticulum-connections.md), [ble](docs/ble.md),
[mesh](docs/mesh.md), [torrents](docs/torrents.md), [circles](docs/circles.md).

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

The bundled wapps live in `assets/wapps/`. To rebuild a wapp from source, see the
[`geograms/wapps`](https://github.com/geograms/wapps) repository.

---

## Development

> **Build on the wapp layer, not the core engine — by default.** A wapp updates
> in place: users get it through the Wapp Store, or it ships as a small `.wapp` with
> no reinstall. Changing the **core engine means a whole new APK** the user must
> download and install (and on Android that is a signed-update dance, versionCode
> bumps, and a slow rollout — see [Validation](docs/validation.md)). So the default
> home for new functionality is a **wapp**. Touch the core engine **only when the
> feature genuinely cannot live in a wapp** — a new transport, a HAL primitive a wapp
> needs but can't express, a cross-cutting host service. Keep the host **generic** —
> app-specific logic (Chat conventions, social rules, torrent formats) lives in the
> wapp's C + GeoUI, never in `lib/`. Most changes should land in
> [`geograms/wapps`](https://github.com/geograms/wapps), not here.

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
