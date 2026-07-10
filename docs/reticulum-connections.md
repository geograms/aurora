# Reticulum & APRS-IS connection model (one connection, no duplicates)

Audit note: long-lived network transports must be owned by a single shared
layer, never opened per wapp-engine. A device runs more than one wapp engine for
the same wapp — the foreground `WappPage` engine and the headless background
service engine (and briefly both, during hand-off) — so any connection a wapp
opens directly is at risk of being opened two or three times at once.

## Reticulum (RnsService) — already a singleton, no change needed

`lib/services/reticulum/rns_service.dart` is the one place that talks RNS:

- `RnsService.instance` is a process-wide singleton — one RNS node for the whole
  app, shared by every engine.
- `start()` is idempotent: `if (_up || _starting) return _up;`. Repeated starts
  (and `rns_autostart`, which runs on every launch / network change) cannot spin
  up a second node or a second set of uplinks.
- Hub uplinks are deduped per `host:port` via the `_connectedHubs` set:
  `connectUplink()` returns early if the hub is already held, and `_dropClient()`
  clears it so a reconnect re-adds exactly one. The initial `tcpclient` connect
  registers the same key.
- Wapp engines never open RNS connections. They attach to the singleton through
  per-wapp *channels* (`wappRegister(tag)` → a per-wapp inbox), so N engines
  share one node and one set of hub connections.

Verified on-device: TCP connections to the RNS port (4242) show one connection
per *distinct* hub (the deliberate multi-hub mesh), with no hub appearing twice.

Since Chat v0.2.109, Reticulum is the Chat wapp's **primary** transport (1:1,
groups, geo-chat, Activity feed and manual beacons all ride RNS first); BLE is
the local path and APRS-IS is legacy/opt-in (licensed callsign required).

## APRS-IS — why it duplicated, and the fix

The APRS wapp did NOT go through a singleton: it opened a raw TCP socket itself
via `hal_socket_*`, so the foreground engine, the background engine, and leaked
reconnect sockets each opened their own connection to APRS-IS — all logging in
with the same callsign. APRS-IS allows one login per callsign and kicks the
duplicates, which put the link into a permanent reconnect war (observed: three
simultaneous connections to one service). Outgoing 1:1 messages frequently fell
through to BLE only because the link was rarely stably up.

Fix (`lib/wapp/wapp_engine.dart`): the socket HAL now shares ONE real TCP
connection per `(host, port)` across all engines (`_SharedSocket`, keyed in a
static map). Each `hal_socket` handle is a refcounted *view* with its own RX
buffer; inbound bytes fan out to every view; the duplicate APRS-IS login line is
suppressed (only the first `user …` is sent); the real socket closes when the
last view is released. Result: one connection, one login, no kick war.

## Rule for new transports

Any new always-on/long-lived connection (another internet relay, a second
socket protocol, etc.) must be owned by a singleton host service (like
`RnsService`) or share at the HAL layer (like the APRS-IS socket fix) — never an
unmanaged per-engine `hal_socket_open`/`Socket.connect`. Otherwise the
foreground + background engines will duplicate it.
