# Releases & distribution

How Geogram Aurora ships updates and how the wapp store gets its catalog.

The guiding constraint: **the running app must never depend on github.com**
(app-store policy). Everything the app fetches at runtime comes from
**https://geogram.radio**. GitHub is used only as the build/CI backend — end
users only ever talk to geogram.radio.

---

## 1. The big picture

```
  geograms/aurora (source + CI)            geograms/wapps (wapp sources + binaries)
        │                                          │
        │ release.yml on tag vX.Y.Z                │ build-archive.sh commits binaries/
        │  • build android/linux/windows           │
        │  • publish_release.dart writes           │
        │    updates/ INTO ITS OWN repo            │
        ▼                                          ▼
   geograms/aurora/updates/              geograms/wapps/binaries/
        │                                          │
        └──────────────┬───────────────────────────┘
                       │  geograms/geogram-html  ·  sync.yml (cron + manual)
                       │   copies updates/ -> updates/  and  binaries/ -> wapps/
                       ▼   (commits to itself with the default GITHUB_TOKEN)
              geograms/geogram-html  ──GitHub Pages──►  https://geogram.radio
                       │                                   /updates  (app updates)
                       │                                   /wapps    (wapp store)
                       ▼
                  the app reads ONLY geogram.radio
```

Three repos, one website:

| Repo | Role |
|------|------|
| `geograms/aurora` | The Flutter app + release CI. On a tag it builds the 3 platforms and commits the **update feed** into its own `updates/`. |
| `geograms/wapps` | Wapp C sources + built `.wapp` packages in `binaries/` (with `index.json`). |
| `geograms/geogram-html` | The geogram.radio website (GitHub Pages, `CNAME = geogram.radio`). Its `sync.yml` **copies** the published files from the other two repos into itself. |

**No deploy keys / secrets anywhere.** Each workflow uses only the automatic
`GITHUB_TOKEN`: write to its own repo, read from public repos.

---

## 2. What the app reads at runtime

### App updates — `https://geogram.radio/updates`
`lib/services/update_service.dart` (`UpdateService`):
- Stable channel → `<feed>/stable.json`
- Beta channel → `<feed>/beta.json`
- `_feedUrl` defaults to `https://geogram.radio/updates`, persisted as the
  `update.feedUrl` preference, **editable at runtime** in Settings → Updates
  ("Release source" card → `_editFeedUrl`). Blank resets to default.
- A `404` on a channel = "no release on that channel", not an error.
- Parsing: `ReleaseInfo.fromFeed(json, baseUrl)` in `lib/services/update_models.dart`.
  Relative asset URLs are resolved against the directory the channel file was
  fetched from.
- Per-platform asset selection: `assetFor()` (android `.apk` non-debug,
  linux `*linux-x64.tar.gz`, windows `*setup.exe`).
- Apply: `lib/services/update_native_io.dart` (Android installer / Windows
  silent setup / Linux tar swap). Web is a no-op.

### Wapp store — `https://geogram.radio/wapps`
The store is the `install` wapp (`wapps/install/main.c`):
- `DEFAULT_SOURCE = "https://geogram.radio/wapps"`. The store appends
  `/index.json` to fetch the catalog and downloads `<base>/<file>` per entry.
- The catalog fetch uses the real `hal_http_*` HAL (implemented in
  `lib/wapp/wapp_engine.dart`, backed by `HttpTransport`); the `.wapp` download
  goes through the host `wapp.install` message → `installFromUrl`
  (`lib/wapp/wapp_page.dart`).
- First-run source seed priority (`wapp_page.dart`):
  1. host pref `PreferencesService.wappStoreSource` (if set),
  2. in-repo `wapps/binaries/` (dev checkout only),
  3. the wasm's built-in `DEFAULT_SOURCE` (geogram.radio).
- Users can change the source live in the store's own Settings tab (KV `source`).

---

## 3. Feed formats

### Update channel — `updates/stable.json` / `updates/beta.json`
```json
{
  "version": "1.0.1",
  "tagName": "v1.0.1",
  "name": "Geogram Aurora 1.0.1",
  "body": "release notes (markdown)",
  "publishedAt": "2026-06-09T18:18:50Z",
  "prerelease": false,
  "assets": [
    { "name": "aurora.apk",                   "url": "v1.0.1/aurora.apk",                   "size": 97752265 },
    { "name": "aurora-linux-x64.tar.gz",       "url": "v1.0.1/aurora-linux-x64.tar.gz",       "size": 20608322 },
    { "name": "aurora-windows-x64-setup.exe",  "url": "v1.0.1/aurora-windows-x64-setup.exe",  "size": 16188044 }
  ]
}
```
- Asset `url`s are **relative to the `updates/` dir** so the feed is host-agnostic.
- Binaries live under `updates/v<version>/`.
- `beta.json` always points at the newest build; `stable.json` only at
  non-pre-release versions. (Beta users get stable releases too, because a
  stable publish writes BOTH files.)

### Wapp catalog — `wapps/index.json`
```json
[
  {"file":"maps/maps-1.0.1.wapp","id":"tools.geogram.maps","version":"1.0.1","size":13128,"title":"Maps","description":"..."},
  ...
]
```
One entry per wapp; `file` is resolved against the catalog base
(`https://geogram.radio/wapps`).

---

## 4. Cutting a release

```sh
./release.sh 1.0.1          # or ./release.sh 1.0.1-beta.1 for a beta
./release.sh                # auto-bump patch (or the prerelease counter)
./release.sh 1.0.1 -y       # skip the confirmation prompt
```

`release.sh` bumps `pubspec.yaml`, syncs `lib/version.dart` (via
`tool/update_version.dart`), commits `Release vX.Y.Z`, tags `vX.Y.Z`, and
pushes the branch + tag. It does **not** create a GitHub release — pushing the
tag is what triggers the pipeline.

### What happens next (automatic)
1. **`.github/workflows/release.yml`** fires on the `v*` tag:
   - jobs `android` / `linux` / `windows` build and `upload-artifact`;
   - job `publish` (needs all three, `permissions: contents: write`) checks out
     `main`, downloads the artifacts, runs `tool/publish_release.dart --site .`
     (writes `updates/v<ver>/` + `stable.json`/`beta.json`, prunes with
     `--keep 3`), and commits + pushes the feed to **aurora's own repo** using
     the default `GITHUB_TOKEN`.
2. **`geograms/geogram-html` `.github/workflows/sync.yml`** (cron every 3h, or
   trigger manually) copies `aurora/updates → updates/` and
   `wapps/binaries → wapps/`, commits to itself.
3. **GitHub Pages** serves it at geogram.radio (~1 min to deploy).
4. The app's next update check sees the new version.

To skip the wait for the cron, trigger the mirror immediately:
```sh
gh workflow run sync.yml -R geograms/geogram-html
```

---

## 5. Publishing manually (no CI)

If you build the artifacts yourself, publish straight into a local checkout of
the website repo (you can push it; that publishes it):

```sh
dart run tool/publish_release.dart \
  --site /path/to/geogram-html \
  --version 1.0.1 \
  --name "Geogram Aurora 1.0.1" \
  --keep 3 \
  build/app/outputs/flutter-apk/app-release.apk \
  dist/aurora-linux-x64.tar.gz \
  build/installer/aurora-windows-x64-setup.exe
# then: cd /path/to/geogram-html && git add updates && git commit && git push
```

`--keep N` (default 5) prunes old `updates/v<version>/` dirs — it keeps the N
newest by semver **plus** whatever `stable.json`/`beta.json` reference.
The tool imports only `dart:` libraries, so it runs standalone (no `pub get`):
`dart tool/publish_release.dart ...`.

The wapp catalog has its own mirror helper:
```sh
# in geograms/wapps, after ./build-archive.sh
./publish-to-website.sh /path/to/geogram-html   # rsync binaries/ -> wapps/
```

---

## 6. The website repo (geogram.radio)

`geograms/geogram-html`, GitHub Pages from `main` root, `CNAME = geogram.radio`.

- **`.nojekyll` at the root is REQUIRED.** Without it, GitHub Pages runs Jekyll
  and drops the binary `.wapp` packages and JSON under `/wapps` and `/updates`
  (they 404). The site is a static SPA, so disabling Jekyll is safe and correct.
- Layout served:
  ```
  /updates/stable.json  /updates/beta.json  /updates/v<ver>/<binaries>
  /wapps/index.json     /wapps/<name>/<name>-<ver>.wapp
  ```
- `sync.yml` is the only thing that should write `/updates` and `/wapps` — it
  mirrors from the source repos, so don't hand-edit those dirs.

---

## 7. CI workflows summary

| Workflow | Repo | Trigger | Does |
|----------|------|---------|------|
| `release.yml` | aurora | tag `v*` | build 3 platforms → commit feed into `aurora/updates/` |
| `build-android.yml` / `build-linux.yml` / `build-windows.yml` | aurora | push to `main` | CI build verification only (`upload-artifact`, no publish) |
| `sync.yml` | geogram-html | cron `0 */3 * * *` + manual | copy wapps catalog + aurora feed into the website, commit |

---

## 8. Gotchas & decisions

- **No secrets, by design.** An earlier version pushed from aurora to the
  website via an SSH deploy key (`WEBSITE_DEPLOY_KEY`). That was replaced: the
  website pulls/copies from the public source repos with the default token. If
  you ever make a source repo private, the sync would need a token with read
  access to it.
- **Binaries in git history (tradeoff).** `release.yml` commits the built
  binaries (the APK is ~100 MB) into aurora's own repo, and `sync.yml` copies
  them into geogram-html. `--keep` bounds the *working tree*, but git *history*
  still grows. The clean alternative — still secret-free — is to publish
  binaries as GitHub *release assets* on aurora and have `sync.yml` download
  those instead of committing them. Switch if repo size becomes a problem.
- **Not Git LFS.** GitHub Pages does not serve LFS-tracked files over the Pages
  URL (they 404), so binaries are stored as plain files, not LFS.
- **Node 20 deprecation warnings** on `actions/checkout` / `upload-artifact` /
  `download-artifact` are cosmetic until GitHub forces Node 24 (2026); bump the
  action versions when convenient.
- **Runtime is configurable.** Both the update feed URL (Settings → Updates) and
  the wapp store source (store Settings tab, or the `wappStoreSource` pref) can
  be repointed at runtime — useful if geogram.radio ever moves.

---

## 9. Verified reference run — v1.0.1 (2026-06-09)

First real end-to-end release:
- `release.yml` built all 3 platforms and committed
  `updates/{stable,beta}.json` + `updates/v1.0.1/` to aurora — green, no secret.
- `sync.yml` mirrored it to geogram-html — green, no secret.
- Live on geogram.radio:
  - `GET /updates/stable.json` → 200, version `1.0.1`
  - `GET /updates/v1.0.1/aurora.apk` → 200, 97,752,265 B
  - `GET /updates/v1.0.1/aurora-linux-x64.tar.gz` → 200, 20,608,322 B
  - `GET /updates/v1.0.1/aurora-windows-x64-setup.exe` → 200, 16,188,044 B
  - sizes match the feed; range requests supported.
