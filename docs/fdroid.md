# F-Droid readiness

Every network host the Android binary can reach, audited by scanning the built
APK (`app-arm64-v8a-release.apk`) rather than the source. Constants that survive
into `libapp.so`, and blobs introduced by dependencies, do not appear in a search
over `lib/`. Both cases occurred here.

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

Section 1.3, the optional non-free services to declare, is the only remaining
decision. Sections 1.1 and 1.2 are resolved.

### 1.1 `libbarhopper_v3.so`, removed

Resolved. `mobile_scanner` (Google ML Kit barcode scanning) shipped
`libbarhopper_v3.so`, a 4.2 MB proprietary blob, for one feature: the `qr.scan`
GeoUI verb. The dependency is gone, along with the scanner page, the CAMERA
permission and the `android.hardware.camera` feature.

`qr.scan` now answers `{"type":"qr.scanned","text":"","error":"nocamera"}` on
every platform, which is the reply the desktop build always gave. The only
consumer, the torrents wapp, already handled it by falling back to pasting the
link. QR code generation is unaffected, being pure Dart.

To restore QR reading, use a free decoder such as `flutter_zxing` (zxing-cpp,
Apache-2.0) or pure-Dart `zxing2` with the `camera` plugin, and restore the
CAMERA permission with it.

Effect on the arm64 APK: 61.4 MB reduced to 55.6 MB. The native libraries are
now only `libapp.so`, `libflutter.so`, `libwasm_run_dart.so`, `libsqlcipher.so`,
`libdartjni.so` and `libdatastore_shared_counter.so`.

### 1.2 Self-update

The Update Center downloads and installs APKs from `geogram.radio`. F-Droid is
the updater for what it ships and rejects apps that update themselves.

Handled: build with `--dart-define=SELF_UPDATE=false` and
`UpdateService.supported` is false, so every check, download and install path
short-circuits and the Settings entry is hidden. Use that flag for the F-Droid
build. Direct-download builds retain it.

### 1.3 Optional non-free services (declare, do not remove)

Reachable only after the user configures them; inert in a fresh install:

| Host | What | Gate |
|---|---|---|
| `api.anthropic.com`, `api.openai.com`, `api.deepseek.com` | AI providers | `requiresApiKey == true`, inert without a user key. A free local provider, Ollama, ships alongside them. |
| `rotate.aprs2.net:14580` (in `chat.wapp`) | APRS-IS | Off by default; needs a licensed callsign + verified passcode. Server software (javAPRSSrvr) is proprietary freeware. |
| `ice1.somafm.com` (in `mp4player.wapp`) | Three seeded demo radio streams | Free-to-listen Icecast, over plain http, so worth replacing or dropping if cleartext is questioned. |

Suggested F-Droid anti-feature: NonFreeNet. The optional AI providers and
APRS-IS are proprietary services, although nothing depends on them.

---

## 2. Fixed during this audit

| Was | Now | Why |
|---|---|---|
| `server.arcgisonline.com` as the default map tiles | `tile.openstreetmap.org` | Esri is a proprietary service, and it was the default every user received without choosing. A wapp can still set `tile-url`. |
| `install.wapp` rewrote `github.com` tree URLs to `raw.githubusercontent.com` | rewriter deleted; the configured URL is used verbatim | No GitHub code path in the shipped binary. |
| Update Center always offered | hidden when `SELF_UPDATE=false` | Dead path should not have a door. |

## 3. Hosts that remain, and why each is fine

**Free-software services, used by default**

| Host | Purpose |
|---|---|
| `geogram.radio` | Update feed + wapp catalog. Self-hosted by the project. |
| `tile.openstreetmap.org`, `nominatim.openstreetmap.org` | Map tiles and search (ODbL). |
| `relay.damus.io`, `nos.lol`, `relay.nostr.band`, `relay.primal.net`, `purplepag.es` | Default NOSTR relays, open protocol, all replaceable in Settings. |
| `blossom.primal.net`, `nostr.download` | Blossom blob servers (open protocol). |
| `reseed.i2p-projekt.de`, `reseed.stormycloud.org`, `reseed.diva.exchange`, `banana.incognet.io`, `i2pseed.creativecowpat.net`, `reseed-fr.i2pd.xyz`, `reseed.onion.im` | Standard I2P reseeds. |
| `rns.beleth.net:4242` (in `mesh.wapp`) | Default Reticulum hub. |
| `njump.me` | Renders `nostr:` links (open source). |

**Strings that are not network calls**

| String | Where | Why it is inert |
|---|---|---|
| `github.com/juancastillo0/wasm_run/releases/` | `libapp.so` | `setUpDesktopDynamicLibrary` is a desktop setup helper. Nothing in this app calls it, and Android loads the bundled `libwasm_run_dart.so`. Verified: no caller in `lib/` or `tool/`. |
| `github.com/Baseflow/flutter-permission-handler/issues`, `github.com/flutter/flutter/issues/` | `classes.dex` | Text inside exception messages. |
| `schemas.android.com`, `www.unicode.org`, `android.googlesource.com`, `issuetracker.google.com`, `docs.flutter.dev`, `dartbug.com`, `bytecodealliance.org`, `docs.rs`, `youtrack.jetbrains.com`, `ns.adobe.com`, `www.apache.org` | toolchain/runtime libs | XML namespaces, licence headers, doc links in AOSP/Flutter/Kotlin/Rust runtimes. |
| `cdn.jsdelivr.net` | `browser_wasi_shim.js` | A web-target asset of `wasm_run`, never loaded on Android. |

Absent from the APK: Firebase, Play Services, Google Analytics, Tag Manager,
Crashlytics, and any advertising or tracking SDK. `googletagmanager.com`,
`analytics.google.com` and `ip-api.com` appear only under `esp32/`, which is
firmware for separate hardware and not part of this build.

## 4. Permissions worth explaining in the submission

`INTERNET`, `ACCESS_NETWORK_STATE`, `BLUETOOTH_*` + `ACCESS_FINE_LOCATION`
(BLE mesh: Android ties BLE scanning to location; `BLUETOOTH_SCAN` is declared
`neverForLocation`), `READ/WRITE_EXTERNAL_STORAGE` (identity backup + shared files),
`FOREGROUND_SERVICE` (the mesh and Reticulum node must survive screen-off),
`RECEIVE_BOOT_COMPLETED` (restart the node after a reboot).
