# Encrypted Profile Storage

Status: phases 1–4 implemented (crypto core, SQLCipher databases, profile.ear loose files, unlock UI + enable/disable). Phase 5 (headless remember-key on Android boot + locked notification) pending. This document specifies how Aurora encrypts each profile's user data at rest.

## Context

Each Aurora profile (`devices/<id>/`) holds private user data — chat history, messages, media, wallet, folder keys — today all plaintext. Requirement: profile data encrypted at rest, unlocked with a user password (emoji allowed) **mixed with the profile's nsec**. The earlier geogram iteration (`/home/brito/code/geogram/geogram`) already built the hard part: a proven `encrypted_archive` Dart package (SQLite container `EARCH01`, Argon2id → wrapped random master key → HKDF per-file keys → AES-256-GCM chunks, streaming, password change = re-wrap only). Old geogram derived the key from nsec only — the user password + emoji mix is new here.

**Approved decisions:**
1. **No plaintext ever on disk** — extract-to-disk/repack explicitly rejected.
2. **Container = encrypted folder**: `devices/<id>/` holds one `profile.ear` (all loose files) + SQLCipher-encrypted `.sqlite3` files (live DBs can't run inside an archive).
3. **Scope = user data only**: `data/` tree, avatar, identity, folder keystore, and ALL `.sqlite3` DBs (incl. `wapps/<w>/social.sqlite3`); wapp code files (`manifest.json`, `app.wasm`, screens) stay plaintext.
4. **Headless boot = optional remember-key**: "Keep unlocked on this device" caches derived keys app-private; otherwise gated services wait for manual unlock.
5. **nsec encrypted at rest too** (in `profiles.json`, identity-backup-style AES-GCM envelope).
6. Per-profile opt-in toggle. **No data migration**: enabling encryption deletes the old plaintext files and starts fresh encrypted; disabling deletes encrypted data.

## Key hierarchy

```
password  = NFC-normalized user string (emoji OK; ZWJ/skin-tone sequences preserved), utf8-encoded
nsec      = profile secret (bech32 string; use decoded 32 bytes as ikm component)

salt      = random 16 B, stored plaintext in the profile's keyslot
KEK_pw    = Argon2id(password, salt, t=3, m=64 MiB, p=1) → 32 B          # stage 1
nsec_ct   = AES-256-GCM(KEK_pw, nsec)            → stored in profiles.json entry
KEK       = HKDF-SHA256(ikm = KEK_pw ‖ nsecBytes, salt, info="aurora-profile-kek-v1")  # password × nsec mix
PMK       = random 32 B profile master key (generated once at enable)
pmk_ct    = AES-256-GCM(KEK, PMK)                → devices/<id>/keyslot.json
earPass   = hex(HKDF(PMK, info="aurora-ear-v1"))          → password for profile.ear
dbKey(p)  = HKDF(PMK, info="aurora-db-v1:" + relPath) → 32 B → PRAGMA key = "x'<hex>'"
remember  = {PMK, nsec} in app-private prefs (Android Keystore wrap = later hardening)
```

- Wrong password detected by GCM auth failure on `nsec_ct` (no oracle, constant-time).
- Off-device theft of `devices/<id>/` needs password **and** nsec. Password change = re-derive KEK, re-wrap PMK + nsec (cheap; archive/DBs untouched).
- NFC normalization: add `unorm_dart` (tiny, pure Dart) so the same emoji typed on different keyboards derives the same key.

## Components

### 1. Port `encrypted_archive` package
Copy `/home/brito/code/geogram/geogram/packages/encrypted_archive` → `aurora/packages/encrypted_archive`. All deps already in aurora (`sqlite3`, `cryptography`, `crypto`, `archive`).
**Modification**: add **sync** read/write/exists paths (AES-GCM via `pointycastle`'s `GCMBlockCipher` — sync; the `cryptography` package is Future-only) so the WASM HAL sync callbacks (`ProfileStorage.readBytesSync` etc., `lib/profile/profile_storage.dart:80-96`) work. Argon2id stays async (unlock-time only).

### 2. SQLCipher for live databases
- `pubspec.yaml`: replace `sqlite3_flutter_libs` → `sqlcipher_flutter_libs` (mutually exclusive; `package:sqlite3` API unchanged). **Verify Linux/Windows support first thing in this phase**; fallback = ship libsqlcipher via CMake for desktop.
- New central opener `lib/profile/profile_db.dart`: `Database openProfileDb(String absPath)` — consults `ProfileKeyring`; encrypted profile → `sqlite3.open(path)` + `PRAGMA key="x'<dbKey>'"`, plain profile → open as today (SQLCipher reads plain DBs when no key set).
- `reticulum-dart` (sibling, path dep): add injectable opener hook `Database Function(String path)` used by `MediaArchive`, `observed_store.dart:32`, social/event stores; aurora injects `openProfileDb` at startup.
- Replace direct `sqlite3.open` call sites: `mesh_store.dart:57`, `geo_chat_archive.dart:35-39`, `activity_archive.dart:22-26`, `coin_host_bridge.dart:123,160`, `wapp_social_store.dart:34-35`, `rns_autostart.dart:65-80`, `remote_api_service_io.dart:485-497`, `wapp_engine.dart:2177` (`hal_sqlite_open`), `media_view.dart:43`, `wapp_engine.dart:643-649`.

### 3. `EncryptedProfileStorage` (loose files → profile.ear)
- New `lib/profile/profile_storage_encrypted.dart` implementing the existing `ProfileStorage` interface (`lib/profile/profile_storage.dart:40`, `isEncrypted` flag already there) backed by `devices/<id>/profile.ear`; sync variants via the sync archive API.
- Selection in `ProfileService.activeProfileStorage()/storageForProfile()` (`lib/profile/profile_service.dart:184,233`): keyslot exists → encrypted backend (throws `ProfileLockedException` if keyring locked), else filesystem.
- **Boundary rule** inside encrypted profile: `wapps/<w>/` non-sqlite files + `.seeded.json` + `keyslot.json` stay filesystem-plaintext; every `*.sqlite3` = SQLCipher on filesystem; everything else (data/ loose files, avatar.png, folders.json, disk_folders.json) = inside `profile.ear`.
- Reroute bypass call sites to `ProfileStorage`: `wapp_engine.dart:1747-1807,3397-3400` (`hal_file_*` raw `dart:io`), `disk_folder_manager.dart:268-283`, `folder_keystore.dart` (folder master privs — high-value secrets), remote API file serving (`remote_api_service_io.dart` — audit during phase).

### 4. Unlock flow + keyring
- New `lib/profile/profile_keyring.dart`: singleton holding `{PMK, nsec}` per unlocked profile; `unlock(id, password)` (Argon2id → decrypt nsec → KEK → unwrap PMK), `unlockCached(id)` (remember-key), `lock(id)` (close archive + DB handles, zero keys).
- New `lib/profile/unlock_page.dart`: password field (native keyboard emoji fine), "Keep unlocked on this device" checkbox, wrong-password error. Inserted in `launcher_app.dart _home()` (`lib/launcher/launcher_app.dart:127-180`): active profile encrypted && locked → `UnlockPage` before `LauncherPage`.
- Headless (`main.dart`): after `profile-service` boot task, encrypted+locked → try cached key; none → **skip** `PermissionGate.startGatedServices()` (`main.dart:311`) and post notification "Aurora locked — tap to unlock" via BgService channel.
- Profile switcher (`launcher_page.dart:718-775`): lock badge on encrypted profiles; switching to one routes through UnlockPage.
- Manual "Lock now" in profile edit page. No auto-relock timer in v1.

### 5. Enable/disable — no data migration
No plain↔encrypted data conversion machinery. In profile edit page (near identity-backup passphrase UI, `profile_edit_page.dart:53-134` pattern):
- **Enable**: choose password (twice) + warning ("no recovery; existing profile data will be deleted") → stop gated services & close all profile DB/archive handles → **delete old plaintext data files** (`data/` tree, profile `.sqlite3` DBs, avatar, folder keystore) → generate salt+PMK, write keyslot, encrypt nsec in `profiles.json` → profile continues fresh, all new writes encrypted.
- **Disable**: delete encrypted data files + keyslot, restore nsec to plaintext entry → fresh plaintext profile.
- Password change: re-wrap only (keeps data).
- When encryption on: identity backup mirror (`identity_backup.dart`) must be passphrase-encrypted (force or strongly warn — else nsec leaks to `/storage/emulated/0/Aurora`).

## Phases (each shippable)

1. **Crypto core**: port+modify `encrypted_archive`, `ProfileCrypto` key hierarchy, `unorm_dart`; unit tests incl. emoji/ZWJ passwords, wrong password, password change.
2. **SQLCipher plumbing**: dep swap (verify desktop platforms), `openProfileDb`, reticulum-dart hook, migrate all call sites; plain profiles must behave identically (regression: run app, chat, media).
3. **EncryptedProfileStorage + reroutes**: hal_file, folder keystore, remote API; selection logic.
4. **Unlock UI + enable/disable + nsec envelope**: UnlockPage, enable/disable (delete-old-files, no conversion), switcher badges, password change UI.
5. **Headless remember-key**: cached-key unlock in headless boot, locked notification, gated-services skip.

## Verification

- `flutter analyze` + unit tests (`test/`): key derivation vectors, emoji NFC stability, archive round-trip, sqlcipher round-trip, enable/disable flows.
- Desktop live: create profile → enable encryption (confirm old files gone) → use chat/media → restart → unlock (wrong then right password) → data intact. Then `strings`/`hexdump` over `devices/<id>/` files: no plaintext message content anywhere; `file profile.ear` + sqlite3 CLI on DBs must fail without key.
- Plain-profile regression on desktop after Phase 2 (no key, identical behavior).
- Android: build via `~/bin/android-build-locked`, deploy to C61; test unlock UI, remember-key + headless restart, background chat reception locked vs unlocked.

## Risks

- `sqlcipher_flutter_libs` desktop (Linux/Windows) support — verify day 1 of Phase 2; fallback CMake-built libsqlcipher.
- SQLCipher ~5-15 % DB overhead; Argon2id 64 MiB at unlock on low-RAM phones (one-shot, acceptable).
- `PreferencesService.wappDataDir` override can point `data/` outside the profile — opener still keys those DBs, but loose files there won't be in the .ear; document limitation.
- Deletion of old plaintext files is best-effort on flash (wear-leveling defeats overwrite); enabling encryption early, before data accumulates, is the real protection.
- Changes span two repos (aurora + reticulum-dart).
