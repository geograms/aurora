# Notifications

How any wapp or host code raises a notification in geogram, and how notifications
travel from an in-app card all the way to an OS-level toast on the desktop or Android.

> **Not covered here:** the Activity feed (`lib/wapp/geoui/widgets/activity_feed.dart`)
> is a Twitter/X-style social micro-blog stream. Despite the name overlap it is **not**
> part of the notification pipeline — it displays social posts and reports user gestures
> back to its wapp via callbacks; it never calls `NotificationService`. Don't conflate them.

## TL;DR

- **One entry point:** `NotificationService.instance.show(GeogramNotification(...))`.
- **From a wapp:** send an outbox message `{"type":"notify", ...}` via `hal_msg_send`.
  There is no dedicated `hal_notify` symbol — `notify` is a message *type*.
- **Severity:** `info | success | warning | error`.
- **Reach:** `scope: app | system | both` decides whether it stays in-app or escalates
  to the OS (system tray on Linux/macOS, `NotificationManager` on Android).
- **Dedupe:** set a `tag`; a given tag is shown **once, ever**.

## Architecture

```
wapp C code
  hal_msg_send('{"type":"notify","level":"warning","title":"...","scope":"both"}')
      │  (WasmImport 'hal'.'msg_send' → wapp_engine._outbox)
      ▼
host drains the wapp outbox:
  foreground wapp → wapp_page._drainOutbox        (scope respected)
  headless  wapp  → BackgroundWappManager         (scope forced to 'both')
      ▼
NotificationService.instance.show(GeogramNotification)      lib/services/notification_service.dart
  ├─ dedupe by tag, append to in-memory history (cap 200)
  ├─ fire NotificationShownEvent on the EventBus
  │     ├─ NotificationLayer  → in-app stacking overlay      (scope app|both)
  │     └─ NotificationStore  → persist + unreadCount → bell badge / NotificationsPage
  └─ SystemTrayNotificationBackend                           (scope system|both)
         → platform.showSystemNotification
             ├─ Linux  : notify-send
             ├─ macOS  : osascript display notification
             ├─ Android: MethodChannel bg_service 'notify' → BgBridge → NotificationManager
             ├─ Windows: not implemented (planned: winrt toast)
             └─ Web    : no-op
```

The whole system lives behind one service. Every path — wapp, host code, or an error on
the EventBus — funnels through `NotificationService.instance.show(...)`.

## The data model

`lib/services/notification_service.dart`

```dart
enum NotificationLevel { info, success, warning, error }   // severity
enum NotificationScope { app, system, both }               // reach; app is the default

class GeogramNotification {
  final NotificationLevel level;
  final String title;
  final String? body;
  final String source;    // "wapp:<wappName>" or "host:<service>"  (see convention below)
  final String? tag;      // dedupe key: a tag is shown once, ever
  final NotificationScope scope;
  final DateTime timestamp;
}
```

**`source` convention:** wapp-sourced notifications use `wapp:<wappName>`, host-sourced
use `host:<service>`. The notification center filters on these prefixes (a `wapp` chip and
a `host` chip), so follow the convention or your notification won't group correctly.

## Types of notifications

### By severity — `NotificationLevel`

| Level     | Meaning                | Desktop/Android treatment                                  |
|-----------|------------------------|------------------------------------------------------------|
| `info`    | neutral status         | in-app card auto-dismiss 3 s; normal OS priority           |
| `success` | operation completed    | in-app card auto-dismiss 3 s                               |
| `warning` | something needs a look  | in-app card, warning color/icon                            |
| `error`   | failure                | in-app card auto-dismiss 6 s; Linux `notify-send --urgency=critical`; Android posts with the error flag |

String parsing accepts aliases: `warn` → `warning`, `err` → `error`. Unknown → `info`.

### By reach — `NotificationScope`

| Scope    | In-app overlay | Persisted + bell badge | OS system notification |
|----------|:--------------:|:----------------------:|:----------------------:|
| `app`    | ✅ (default)    | ✅                      | ❌                      |
| `system` | ❌              | ✅                      | ✅                      |
| `both`   | ✅              | ✅                      | ✅                      |

- `app` (default): shows the in-app stacking overlay card and lands in the notification
  center + bell badge. Never touches the OS.
- `system`: **escalates only to the OS** (tray/Android). Deliberately skipped by the in-app
  overlay so you don't get a card *and* a toast for the same thing.
- `both`: in-app card **and** OS notification. Use when the user might not be looking at
  the app.

> **Headless wapps always escalate.** A wapp running in the background (no visible page)
> can't draw an in-app card, so `BackgroundWappManager` forces `scope: both` on every
> `notify` it drains. That's how a background wapp reaches the user via an Android system
> notification even when the app UI isn't foregrounded.

### Android native channels

At the OS layer, Android sorts notifications into channels (each with its own importance
and user-facing settings). Package `com.geogram.aurora`:

| Channel id          | Label                  | Importance | Used for                                          |
|---------------------|------------------------|-----------|---------------------------------------------------|
| `EVENT_CHANNEL_ID`  | "Messages & events"    | HIGH      | the general `notify` escalation path (heads-up)   |
| `aurora_bg`         | "Background services"  | LOW       | the ongoing foreground-service notification       |
| (updates channel)   | "Updates"              | —         | download/update progress (`DownloadForegroundService`) |
| (media channel)     | —                      | —         | lock-screen media transport (Player wapp)         |

For general notifications, only `EVENT_CHANNEL_ID` matters — it's the high-importance,
heads-up channel `BgBridge` posts to.

### Unread badges are not notifications

Distinct mechanism, same outbox. A wapp can set an app-tile / header badge count without
raising a notification:

```json
{"type":"unread", "count": 3, "intent": "messages"}
```

This drives `WappUnreadService` (keyed by `wappId` and optional `intent`, e.g.
`wappId#messages`). Use `unread` for "there are N things" ambient counts; use `notify`
for "interrupt the user now".

## Raising a notification from a wapp

Wapps are C programs compiled to WASM. They talk to the host by writing a JSON string to
the host outbox via the single host import `hal_msg_send`. To raise a notification, send a
message with `type: "notify"`:

```c
hal_msg_send(
  "{\"type\":\"notify\","
  "\"level\":\"warning\","
  "\"title\":\"Low battery\","
  "\"body\":\"Node X1 reports 12%\","
  "\"tag\":\"batt-x1\","          // optional dedupe key
  "\"scope\":\"both\"}"           // omit → defaults to "app"
);
```

Wire fields:

| Field   | Required | Values                                | Default |
|---------|:--------:|---------------------------------------|---------|
| `type`  | yes      | `"notify"`                            | —       |
| `title` | yes      | string                                | —       |
| `level` | no       | `info`/`success`/`warning`/`error`    | `info`  |
| `body`  | no       | string                                | —       |
| `tag`   | no       | string dedupe key (shown once ever)   | none    |
| `scope` | no       | `app`/`system`/`both`                 | `app`   |

The host sets `source` for you to `wapp:<wappName>` — don't send it yourself.

**Legacy `ui.toast`.** The older shape is still accepted and routed through the same
service as an `info`-level notification, so old wapps inherit tray delivery + history:

```json
{"type":"ui.toast", "message":"Saved"}
```

There is **no `hal_notify` C symbol.** The only host import is `hal.msg_send`; `notify`
is a message type, not a HAL function.

### Routing details

- **Foreground wapp:** `wapp_page._drainOutbox` parses the message and honors `scope` as
  sent (defaults to `app`).
- **Headless wapp:** `BackgroundWappManager` drains the outbox and forces `scope: both`
  (see the callout above) so background notifications always reach the OS.

## Raising a notification from host (Dart) code

Call the service directly, using the `host:<service>` source convention:

```dart
NotificationService.instance.show(GeogramNotification(
  level: NotificationLevel.error,
  title: 'Sync failed',
  body: 'Could not reach hub',
  source: 'host:folders',
  tag: 'folders-sync-fail',   // optional; shown once ever
  scope: NotificationScope.both,
));
```

**Automatic error surfacing.** `NotificationService.init()` subscribes to `ErrorEvent` on
the EventBus, so anything that fires an `ErrorEvent` auto-becomes an `error`-level
notification. You often don't need to raise error notifications by hand — fire the event.

## What the user sees

- **In-app overlay** — `NotificationLayer`: a stacking overlay of up to 5 cards, top-right.
  Not a SnackBar/ScaffoldMessenger (deliberate — it must survive route changes and stack).
  Auto-dismiss 3 s (info/success) / 6 s (error). `scope: system` cards are skipped here.
  Installed via `MaterialApp.builder`, not `home:`.
- **Bell + badge** — `home_header.dart` renders a badged bell bound to
  `NotificationStore.instance.unreadCount`. Opens the notification center.
- **Notification center** — `NotificationsPage`: full-screen list, grouped by day
  (Today / Yesterday / date), filter chips for `all` / `wapp` / `host` and one per level.
  Opening it marks all seen.
- **OS notification** — for `system`/`both`: `notify-send` (Linux), `osascript`
  (macOS), or a heads-up `NotificationManager` post (Android). Tapping the Android one
  opens the launcher.

## Persistence & dedupe

- **In-memory history:** `NotificationService.history`, rolling, capped at 200. Not
  persisted (survives only the process).
- **Persistent store:** `NotificationStore` writes to `notifications/history.jsonl` in the
  active profile (cap 300), with a read cursor in `notifications/seen_ms.txt`. Reloads on
  profile switch. Exposes `items` and `unreadCount` as `ValueNotifier`s.
- **Dedupe by `tag`:** `NotificationService.show` shows a given tag **once, ever**
  (tracked in a `_shownTags` map capped at 500). In the persistent store, a repeated `tag`
  **replaces** the earlier row rather than stacking (the tag is used as the row id). Use a
  stable `tag` for recurring conditions (e.g. `batt-x1`) so you don't spam the user.

## Platform support matrix

| Platform | System notification | Mechanism                                            |
|----------|:-------------------:|-----------------------------------------------------|
| Linux    | ✅                  | `notify-send` (`--urgency=critical` for errors)      |
| macOS    | ✅                  | `osascript -e 'display notification ...'`             |
| Android  | ✅                  | `MethodChannel` `com.geogram.aurora/bg_service` `notify` → `BgBridge` → `NotificationManager` (heads-up, channel "Messages & events") |
| Windows  | ❌                  | not implemented (planned: winrt toast)               |
| Web      | ❌                  | no-op                                                |

The in-app path (overlay + bell + center) works on **all** platforms, so `scope: app`
notifications are always delivered even where OS escalation isn't wired up. No
`flutter_local_notifications` dependency — all native delivery is hand-rolled.

## Key source files

| Path | Role |
|------|------|
| `lib/services/notification_service.dart`        | enums, `GeogramNotification`, `NotificationService`, backends, `NotificationLayer` overlay |
| `lib/services/notification_store.dart`          | persistence + `unreadCount` |
| `lib/launcher/notifications_page.dart`          | notification center UI |
| `lib/launcher/home_header.dart`                 | bell + badge |
| `lib/services/wapp_unread_service.dart`         | `unread` badge counts (separate from notifications) |
| `lib/wapp/wapp_page.dart`                        | foreground wapp outbox → `notify` routing |
| `lib/wapp/background_wapp_manager.dart`          | headless wapp outbox → forces `scope: both` |
| `lib/wapp/wapp_engine.dart`                      | `hal.msg_send` host import binding |
| `lib/platform/platform_io.dart`                 | `showSystemNotification` per-OS dispatch |
| `android/app/src/main/kotlin/com/example/iwi/BgBridge.kt` | Android `notify` handler + channels |
| `android/app/src/main/kotlin/com/example/iwi/BgService.kt`| foreground service keeping headless process alive |
