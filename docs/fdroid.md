# F-Droid readiness — every host the Android binary can reach

Audited by scanning the **built APK** (`app-arm64-v8a-release.apk`), not just the
source: constants that survive into `libapp.so` and blobs pulled in by
dependencies do not show up in a `grep` over `lib/`, and both mattered here.

Reproduce:

```sh
flutter build apk --release --split-per-abi --dart-define=SELF_UPDATE=false
python3 - <<'PY'
import zipfile,re,collections
z=zipfile.ZipFile('build/app/outputs/flutter-apk/app-arm64-v8a-release.apk')
pat=re.compile(rb'(?:https?|wss?)://[A-Za-z0-9._~:/?#@!$&\'()*+,;=%-]{4,70}')
c=collections.Counter()
for n in z.namelist():
    if n.endswith(('.png','.jpg','.webp','.ttf','.otf')): continue
    for m in pat.findall(z.read(n)):
        c[re.sub(r'^\w+://','',m.decode()).split('/')[0].split(':')[0]]+=1
for h,n in c.most_common(): print(n,h)
PY
```

---

## 1. Open items (decide before submitting)

### 1.1 `libbarhopper_v3.so` — proprietary Google blob, 4.2 MB

Pulled in by **`mobile_scanner`** (Google ML Kit barcode scanning), used for
exactly one feature: the `qr.scan` GeoUI verb (`lib/wapp/wapp_page.dart`), which
lets a wapp read a QR code (torrent links, circle short codes).

This is the one hard blocker: F-Droid does not ship non-free binaries. Options,
best first:

| Option | Cost | Result |
|---|---|---|
| Swap to **`flutter_zxing`** (zxing-cpp, Apache-2.0) | ~30 lines + camera test on device | Feature keeps working, no blob |
| **`zxing2`** (pure Dart) + `camera` | more code, slower decode | No native code at all |
| Drop `qr.scan` in the F-Droid flavour | trivial | Feature missing there |

Not changed here: swapping the camera stack needs testing with a real camera,
which is a decision plus a device session, not a blind edit.

### 1.2 Self-update

The Update Center downloads and installs APKs from `geogram.radio`. F-Droid is
the updater for what it ships and rejects apps that update themselves.

**Already handled**: build with `--dart-define=SELF_UPDATE=false` and
`UpdateService.supported` is false, so every check/download/install path
short-circuits and the Settings entry is hidden. Use that flag for the F-Droid
build. Direct-download builds keep it on.

### 1.3 Optional non-free services (declare, do not remove)

Reachable only after the user configures them; inert in a fresh install:

| Host | What | Gate |
|---|---|---|
| `api.anthropic.com`, `api.openai.com`, `api.deepseek.com` | AI providers | `requiresApiKey == true` — dead without a user key. A free local provider (**Ollama**) ships alongside them. |
| `rotate.aprs2.net:14580` (in `chat.wapp`) | APRS-IS | Off by default; needs a licensed callsign + verified passcode. Server software (javAPRSSrvr) is proprietary freeware. |
| `ice1.somafm.com` (in `mp4player.wapp`) | Three seeded demo radio streams | Free-to-listen Icecast; plain **http**, so worth replacing or dropping if cleartext is questioned. |

Suggested F-Droid anti-feature: **NonFreeNet**, because optional AI providers
and APRS-IS are proprietary services even though nothing depends on them.

---

## 2. Fixed during this audit

| Was | Now | Why |
|---|---|---|
| `server.arcgisonline.com` as the **default** map tiles | `tile.openstreetmap.org` | Esri is a proprietary service and it was what every user hit without choosing. A wapp can still set `tile-url`. |
| `install.wapp` rewrote `github.com` tree URLs to `raw.githubusercontent.com` | rewriter deleted; the configured URL is used verbatim | No GitHub code path in the shipped binary. |
| Update Center always offered | hidden when `SELF_UPDATE=false` | Dead path should not have a door. |

## 3. Hosts that remain, and why each is fine

**Free-software services, used by default**

| Host | Purpose |
|---|---|
| `geogram.radio` | Update feed + wapp catalog. Self-hosted by the project. |
| `tile.openstreetmap.org`, `nominatim.openstreetmap.org` | Map tiles and search (ODbL). |
| `relay.damus.io`, `nos.lol`, `relay.nostr.band`, `relay.primal.net`, `purplepag.es` | Default NOSTR relays — open protocol, all replaceable in Settings. |
| `blossom.primal.net`, `nostr.download` | Blossom blob servers (open protocol). |
| `reseed.i2p-projekt.de`, `reseed.stormycloud.org`, `reseed.diva.exchange`, `banana.incognet.io`, `i2pseed.creativecowpat.net`, `reseed-fr.i2pd.xyz`, `reseed.onion.im` | Standard I2P reseeds. |
| `rns.beleth.net:4242` (in `reticulum.wapp`) | Default Reticulum hub. |
| `njump.me` | Renders `nostr:` links (open source). |

**Strings that are not network calls**

| String | Where | Why it is inert |
|---|---|---|
| `github.com/juancastillo0/wasm_run/releases/…` | `libapp.so` | `setUpDesktopDynamicLibrary` is a **desktop** setup helper. Nothing in this app calls it, and Android loads the bundled `libwasm_run_dart.so`. Verified: no caller in `lib/` or `tool/`. |
| `github.com/Baseflow/flutter-permission-handler/issues`, `github.com/flutter/flutter/issues/…` | `classes.dex` | Text inside exception messages. |
| `schemas.android.com`, `www.unicode.org`, `android.googlesource.com`, `issuetracker.google.com`, `docs.flutter.dev`, `dartbug.com`, `bytecodealliance.org`, `docs.rs`, `youtrack.jetbrains.com`, `ns.adobe.com`, `www.apache.org` | toolchain/runtime libs | XML namespaces, licence headers, doc links in AOSP/Flutter/Kotlin/Rust runtimes. |
| `cdn.jsdelivr.net` | `browser_wasi_shim.js` | A **web**-target asset of `wasm_run`; never loaded on Android. |
| `www.tensorflow.org` | `libbarhopper_v3.so` | Inside the blob covered by §1.1 — goes away with it. |

**Not in the APK at all**: no Firebase, no Play Services, no Google Analytics /
Tag Manager, no Crashlytics, no ad or tracking SDK. (`googletagmanager.com`,
`analytics.google.com` and `ip-api.com` appear only under `esp32/` — separate
firmware for external hardware, not part of this build.)

## 4. Permissions worth explaining in the submission

`INTERNET`, `ACCESS_NETWORK_STATE`, `CAMERA` (QR scanning — see §1.1),
`BLUETOOTH_*` + `ACCESS_FINE_LOCATION` (BLE mesh: Android ties BLE scanning to
location), `READ/WRITE_EXTERNAL_STORAGE` (identity backup + shared files),
`FOREGROUND_SERVICE` (the mesh/Reticulum node must survive screen-off),
`RECEIVE_BOOT_COMPLETED` (restart the node after a reboot).
