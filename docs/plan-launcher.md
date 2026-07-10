# Launcher revamp

Plan for restyling Aurora's home screen after the launcher in the `gnpa` repo
(`gnpa/lib/app.dart`, read-only reference).

## Context

Aurora's home screen (`lib/launcher/launcher_page.dart:288`) is a bare
`Scaffold`: an `AppBar` holding the profile switcher and a settings button, over
a flat `GridView` of wapp icons. It surfaces none of what the node actually
knows — whether it's on the internet or BLE-only, what notifications arrived,
what the people you follow have posted.

The revamp adds: hamburger + profile + connection dot, three badged icons
top-right, a hero carousel of network "novelties", a quick-launch row, and an
Android-style all-apps peek.

Everything needed already exists host-side. Nothing here requires new network
code.

**Hard constraints.** `lib/` stays generic — no hardcoded wapp names in host
paths; wapp-specific behaviour is declared in manifests and resolved
generically. All wapp code lives in the `geograms/wapps` repo; wapp-side work is
a called-out follow-up. Real implementations, no stubs.

## Decisions taken

- **Icon targets** — Notifications opens a new host-native panel. Messages and
  Chat each open a wapp at a specific view, resolved generically via a new
  `provides.intents` manifest key.
- **Slider data** — `feedForFollows(follows)` → if empty `popular(window: 2d)` →
  if empty `firehose(limit: 10)`. Never an empty carousel on a connected node.
- **Quick-launch row** — auto: the three most-used wapps by launch count, ties
  broken by most-recent launch.

## Findings that shape the design

Verified against the tree, correcting the initial assumptions:

- `RelayEventStore` is the private field `_relayStore`
  (`lib/services/reticulum/rns_service.dart:173`) with **no public getter** — the
  launcher cannot reach the feed today. One generic getter must be added.
- `RnsService` exposes **no status notifier**. `_up` is a plain bool mutated at
  ~5 sites. A live connection dot needs polling or new wiring.
- `nostrProfile(pubHex)` (`rns_service.dart:4278`) returns key **`pic`**, not
  `picture`.
- `NotificationService` already keeps a capped in-memory `history`
  (`lib/services/notification_service.dart:129`) and fires
  `NotificationShownEvent` on the `EventBus` (`:170`). What's missing is
  *persistence* and *read/unread state* — so the new store **subscribes to the
  event** rather than editing `notification_service.dart`.
- Wapps already emit notifications through the host (`lib/wapp/wapp_page.dart:1699`,
  `source: 'wapp:<name>'`), so a Notifications panel needs **zero wapp changes**.
- `RnsService.lxmfUnreadCount` (`:3551`) + `addLxmfListener` (`:3518`) is a real
  host-native DM unread count — the Messages badge can be live immediately.
- `shared_preferences` is app-global but the launcher rescans per profile
  (`launcher_page.dart:42`). Launch counts and notification read-state **must be
  keyed by the active profile id** or they bleed across profiles.
- `WappUnreadService.counts` (`ValueNotifier<Map<String,int>>`) is keyed by
  wappId — one number per wapp. Messages and Chat may resolve to the *same*
  wapp, so it needs per-intent sub-keys.

## Plan

### New service files

**`lib/services/notification_store.dart`** — persistent notifications + unread.
`StoredNotification {id, level, title, body, source, timestamp}` (toJson/fromJson).
`NotificationStore` singleton: `ValueNotifier<List<StoredNotification>> items`
(newest-first, bounded ~300), `ValueNotifier<int> unreadCount`, `init()`,
`record(GeogramNotification)`, `markAllSeen()`, `clear()`.

`init()` subscribes to `EventBus().on<NotificationShownEvent>` exactly as
`NotificationLayer` does (`notification_service.dart:225`); `record` is wrapped
in try/catch so a store fault cannot starve the notification pipeline. Persisted
as per-profile JSONL via `ProfileStorage`; reloads on
`ProfileService.instance.activeProfileNotifier`. Registered at boot beside
`NotificationService.instance.init()`.

**`lib/services/launch_count_store.dart`** — `increment(wappId)`, `topN(n)`
(count desc, tie-break lastLaunch desc). Thin logic; key I/O lives in
`PreferencesService`.

**`lib/services/novelties_service.dart`** — carousel data.
`NoveltyItem {id, authorPubkey, authorName, authorPic, title, summary, thumbnail, createdAt}`.
`load({limit = 10})` runs the agreed fallback chain against
`RnsService.instance.relayStore` (new getter), returning `[]` when null. Exposes
`ValueNotifier<List<NoveltyItem>> novelties` + `refresh()`.

**`lib/services/social/note_text.dart`** — shared `stripNoteTokens(String)`.
`lib/wapp/geoui/widgets/profile_view.dart:688-697` has this logic as a private
static; extract it so the two regex sets (`tn:`, `file:`, bare http media, `ih:`,
`sz:`) cannot drift, and have `profile_view.dart` call the shared helper.

### New launcher `part` files

`home_header.dart` (`_HomeHeader` + `_BadgedActionIcon`),
`connection_indicator.dart`, `novelties_carousel.dart`, `quick_launch_row.dart`,
`all_apps_sheet.dart`, `notifications_page.dart`, `app_drawer.dart`. All added to
the `part` list in `lib/launcher/launcher.dart`.

`NotificationsPage` mirrors gnpa's (`app.dart:2378`): filter chips, day-grouped
list (Today/Yesterday/date), row card with 44×44 icon, title/subtitle, relative
time. Filter dimension = `NotificationLevel` plus `source` prefix (`wapp:` vs
`host:`) — both already on `GeogramNotification`. `markAllSeen()` in `initState`.

`_NoveltiesCarousel` follows gnpa's `_FeaturedCarousel` (`app.dart:2036`):
`PageView.builder`, height ~172, animated dot indicators, `ClipRRect` radius 16
`Stack` of image + gradient scrim + author chip + title.

### Existing files to modify

- **`lib/launcher/launcher_page.dart`** — `build()` gains `key: _scaffoldKey`,
  `drawer: _AppDrawer`, an `AppBar` built by `_HomeHeader`; the inline settings
  `IconButton` (`:293`) moves into the drawer. `_openWapp` (`:155`) calls
  `LaunchCountStore.increment(...)` and switches the tile clear to
  `clearAll(wappId)`. New `_openWappIntent(String intent)` resolves the target by
  `providedIntents.contains(intent)` — no wapp-name literal — and pushes
  `WappPage(..., initialView: intent)`. `_buildBody()`'s grid relocates into
  `_AllAppsSheet`; `_openFolder`/`_FolderPage` are unchanged.
- **`lib/launcher/wapp_manifest.dart`** — parse `provides.intents` alongside
  `functionalities`/`file_handlers` (`:139-162`); add `List<String> providedIntents`.
- **`lib/wapp/wapp_page.dart`** — add ctor param `initialView`; after the
  `file.open` block (`:1116-1124`) post the mirror
  `{'type':'view.open','view':…}`, then `_engine.handleEvent(); _drainOutbox();`.
  Wapps that don't handle it ignore it, same contract as `file.open`.
- **`lib/services/wapp_unread_service.dart`** — composite keys `wappId#intent`;
  `setCount/countFor/add` take an optional `intent:`; add `totalFor(wappId)`
  (sums base + all sub-keys) and `clearAll(wappId)`. Tile badges switch to
  `totalFor`.
- **`lib/services/preferences_service.dart`** — launch-count schema following the
  `getWappAutostart` pattern, every key namespaced by active profile id:
  `launch.count.$pid.$wappId`, `launch.last.$pid.$wappId`, plus
  `topLaunchedWapps(n)`.
- **`lib/services/reticulum/rns_service.dart`** — one generic getter:
  `RelayEventStore? get relayStore => _relayStore;`
- **Boot wiring** — `NotificationStore.instance.init()` beside
  `NotificationService.instance.init()`.

### Connection indicator

```
!isUp                                                     → GREY
mode.startsWith('tcp') && (connectedHubs.isNotEmpty
                           || mode == 'tcpserver')        → GREEN
mode.startsWith('ble') || isBleBridge                     → BLUE
otherwise                                                 → GREY
```

Colors from gnpa: green `0xFF52C77E`, blue `0xFF4A90E2`, grey `0xFF6B717E`.

**Liveness: a 2 s `Timer.periodic` inside the widget's `State`, not a new
notifier.** `_up`/`connectedHubs` are mutated at ~5 unrelated sites with no
notification hook; retrofitting a `ValueNotifier` means auditing every mutation
and risks missing one, which fails silently as a stale dot in a generic engine
file. Reading four getters every 2 s is O(1) and fully isolated; the timer is
cancelled in `dispose()`. A `ValueNotifier<RnsStatus>` on `RnsService` is the
cleaner follow-up once the mutation sites are consolidated.

### Badges

- **Notifications** — `NotificationStore.unreadCount` (`ValueNotifier`). Live day
  one.
- **Messages** — `RnsService.lxmfUnreadCount` (wrapped in a notifier fed by
  `addLxmfListener`) **plus** `WappUnreadService.countFor(wappId, intent: 'messages')`.
  The two count different systems (host LXMF DMs vs the wapp's own 1:1 store), so
  no double-count. Live day one via the LXMF half.
- **Chat** — `WappUnreadService.countFor(wappId, intent: 'chat')`. **Reads 0
  until the chat wapp is updated** to emit intent-tagged counts. Stated plainly
  rather than faked with a fallback.

New HAL message for wapps to report per-intent counts —
`{'type':'unread','intent':…,'count':N}` — routed in `wapp_page.dart` beside the
`notify` handler (`:1699`) to `setCount(_wappName, N, intent: …)`. Host plumbing
ships now; badges light up when the wapp lands.

### Novelties wiring

`follows` from `RnsService.instance.follows.asSet` (`rns_service.dart:188`).
Thumbnail: match `\btn:([A-Za-z0-9_-]+=*)` on `event.content`, right-pad to a
multiple of 4, `base64Url.decode` → `Image.memory` (the producer
`_embedNoteThumbnail`, `wapp_page.dart:5052`, already caps it at 40000 chars).
Title/summary from `stripNoteTokens(content)`: first line/sentence → title
(~60 chars), remainder → summary. Author name via `nostrProfile(pubkey)['name']`,
picture `['pic']`, falling back to a short npub; `refreshFollowedProfiles()`
(5-min timer, `rns_service.dart:2269`) keeps these warm.

`RelayEventStore` is sqlite with no change stream, so the feed is **polled**:
refresh on mount, on `AppStartedEvent`, and every 60 s while foregrounded (feed
content moves faster than the 5-min profile timer).

### Layout

`Scaffold(appBar: _HomeHeader, drawer: _AppDrawer, body: Stack)`:

- base `Column`: `_NoveltiesCarousel` (h≈172) then the featured/empty area.
- bottom: `DraggableScrollableSheet(minChildSize≈0.12, maxChildSize: 1.0, snap: true)`.
  The collapsed peek is a grab handle + `_QuickLaunchRow`; dragging up expands to
  the full all-apps grid (the existing `GridView.builder`, wired to the sheet's
  `ScrollController`) with the System/Addons folder tiles at the end.

**`DraggableScrollableSheet`** because it gives drag-to-expand with snap points
*and* shares one `ScrollController` with the inner grid, so the drag becomes a
scroll with no custom gesture code. A modal bottom sheet is wrong — it's
transient, dims the home, and must be re-triggered; the peek must be persistent.
A custom `AnimatedPositioned` + drag would re-implement what this widget already
does.

`_scanArchiveBody`, `_kHiddenWapps`, `_AppIcon` (unread/edited badges, long-press
autostart menu) and `_FolderPage` stay intact — only relocated.

## Ordering

Host-only, each shippable alone:

1. `NotificationStore` + panel + badge
2. Connection indicator
3. Launch counts + quick-launch row
4. `relayStore` getter + `NoveltiesService` + carousel
5. Layout restructure (header, drawer, all-apps sheet)
6. `WappUnreadService` namespacing + `provides.intents` + `view.open` plumbing
   (a harmless no-op until wapps opt in)

**Follow-ups in `geograms/wapps`** (none block host shipping): chat wapp declares
`provides.intents: ["messages","chat"]` (until then the messages/chat icons
resolve nothing and are hidden); handles `view.open` (until then they open the
wapp at its default view); emits per-intent unread (until then the chat badge is
0).

**Regression watch-list:** preserve the profile-switch rescan
(`launcher_page.dart:42`), tile unread badges (now `totalFor`), and the
long-press autostart menu. Key launch counts and notification read-state per
profile. `DraggableScrollableSheet` ↔ `GridView` shared-controller wiring is the
fiddliest piece — build it in isolation first. `tn:` base64url needs manual
padding before decode.

## Verification

- `flutter analyze` clean on both `aurora` and `reticulum-dart` (only the 4
  pre-existing `info` lints in `rns_service.dart`).
- Unit tests: `NotificationStore` (record → unread increments; `markAllSeen`
  zeroes; per-profile isolation; a throwing persist doesn't break the notifier),
  `LaunchCountStore.topN` (count ordering + recency tie-break),
  `NoveltiesService.load` (each rung of the fallback chain; `tn:` decode with and
  without padding; token-stripped title/summary), the connection-state mapping
  table.
- Run the app (`~/bin/android-build-locked flutter run`, per the machine-wide
  build lock): confirm the dot is green on a hub-connected node and grey with RNS
  stopped; fire a notification from a wapp and see it land in the panel with the
  badge incrementing, then clear on open; launch a wapp three times and watch it
  climb into the quick-launch row; drag the peek to full-screen all-apps and
  back, open a folder from the expanded sheet.
- The carousel needs a node with relay events. If `feedForFollows` is empty,
  confirm the `popular` → `firehose` rungs actually populate rather than silently
  rendering an empty `PageView`.
