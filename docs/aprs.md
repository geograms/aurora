# APRS transport — internet (APRS‑IS) and the iGate

APRS is one of Aurora's two **message** transports (the other is
[BLE](ble.md)). It carries chat over the global amateur **APRS‑IS** network when
the internet is up. The *message‑level conventions* (groups, threads, reactions,
signed/encrypted messages, media references) are the same on every transport and
are documented separately in [aprx.md](aprx.md); this doc is about the APRS
**wire + connection** layer as implemented in the APRS wapp
([`wapps/aprs/`](../../wapps/aprs/): `aprs.c`, `main.c`).

---

## 1. APRS‑IS connection

- **Server:** a configurable APRS‑IS host (default `rotate.aprs2.net:14580`).
- **Login & passcode:** the passcode is computed from the callsign
  (`aprs_passcode`); internet APRS‑IS needs only that computed passcode — no
  licence is required to transmit to the IS network.
- **Server‑side filter (`g/` + `b/`):** on login Aurora sends a filter built by
  `build_gfilter` so the server only pushes relevant traffic:
  - `g/<own-call>` — messages addressed to us,
  - `g/<own-call>/<heard-call>…` — messages addressed to **Bluetooth stations we
    have spotted** (so we can iGate them inbound — see §4),
  - `/BLN*` — a catch‑all for bulletins when any *global* group is subscribed
    (APRS‑IS `g/` has no mid‑string wildcard, and a bulletin's addressee is
    `BLN<id><GROUP>`, so the catch‑all is filtered down to subscribed groups
    locally by `deliver_bulletin`),
  - `b/<followed-call>…` — a budlist that pulls every packet from callsigns you
    follow.
- The filter is re‑evaluated periodically; if it changed (e.g. a new BLE station
  was spotted) the wapp reconnects to apply it.

## 2. TNC2 frame format (`aprs.c`)

Aurora reads and writes standard TNC2 text frames:

```
SRCCALL>APRS,<path>:<payload>
```

Builders:

- **Position:** `aprs_build_beacon` → `SRC>APRS,<path>:!<lat><sym1><lon><sym2><comment>`
- **Message:** `aprs_build_message` → `SRC>APRS,TCPIP*::<ADDRESSEE padded 9>:<text>{<seq>`
- **Bulletin (group):** `aprs_build_bulletin` → addressee `BLN<lineid><GROUP>`
  (bulletins carry no `{seq`).

Long messages are split at word boundaries into ≤`max_len` chunks and sent as
lines `0,1,2,…` (`aprs_send_*_multi`), reassembled on the receive side. The
APRX message conventions (the `+<mid>`, `<mid>:like`, `~<sig>`, `ENC1:` markers
in the payload) are layered on top of this — see [aprx.md](aprx.md).

### Path‑parameterised builders

`aprs_build_message_via` / `aprs_build_bulletin_via` take an explicit path. This
matters for iGating (§4): IS‑originated traffic uses `TCPIP*`, while traffic
**gated from another medium** uses a `qAR,<igatecall>` q‑construct.

## 3. Receiving & de‑duplication

Inbound lines are parsed by `aprs_parse` and routed by `route_frame`:

- **positions** → map markers + the Live/geo‑chat feed,
- **messages** → direct‑message reassembly (`da_*`) or, if addressed to a spotted
  BLE station, the store‑and‑forward mailbox,
- **bulletins** → multi‑line reassembly (`ra_*`) then `deliver_bulletin`.

Because the same packet can arrive twice (APRS‑IS + a BLE iGate, or multiple
internet iGates), there are several dedup layers. The conversation layer uses a
**time‑windowed, refresh‑on‑hit** ring (`seen_has`/`seen_add`): an identical
message is suppressed for as long as it keeps arriving inside a 90‑minute window,
so a station that re‑broadcasts the *same* bulletin on a schedule is shown
exactly once (only changed text, or a long quiet gap, gets through again).

## 4. The iGate — bridging Bluetooth ⇄ APRS‑IS

When the node is online **and** Bluetooth is on, it acts as a full **iGate** by
default (`g_ble_relay`, persisted in KV `igate`, default on; toggle in Settings).
It bridges both directions:

### BLE → APRS‑IS (gate out)

A message or bulletin heard over BLE is re‑originated to APRS‑IS **under the
sender's callsign** with a `qAR,<own-call>` q‑construct:

```c
char via[24]; s_cpy(via, "qAR,", …); s_cat(via, g_call, …);
aprs_build_message_via(line, …, from, to, text, 0, via);   // FROM>APRS,qAR,US::TO:text
aprs_send_raw(g_sock, line);
```

> A clean RF‑gated path is essential: an earlier build wrapped the packet as a
> third‑party report with a `TCPIP*` inner path, which APRS‑IS treats as a loop
> and **drops** — so gated traffic never appeared. The `qAR,<igate>` form is the
> textbook RF→IS gateway construct and is accepted.

### APRS‑IS → BLE (gate in)

Because spotted BLE callsigns are in the server `g/` filter (§1), APRS‑IS pushes
messages addressed to them. `route_frame` relays those to BLE for any spotted
addressee (`sdev_has`) or, generally, while the iGate is on. A nice consequence:
when a gated‑out message is acked by its recipient, the ack is addressed to the
original BLE sender — itself a spotted station — so it is relayed *back* over BLE
automatically.

### Store‑and‑forward mailbox

When a BLE‑only station is *not* currently in range, messages addressed to it are
held in a per‑callsign mailbox. The online node beacons `?IGATE`; a BLE station
in reach periodically broadcasts `?MAIL <days> <nonce>` and the iGate replies
with the held messages, newest first, then clears them. The "seen devices"
registry is an LRU of up to 100 callsigns with a 1‑year TTL.

## 5. Channel indicators

The wapp pushes a small status (`ui.map.status`) for each available channel
(`NET`, `BLE`, and room for `LoRa`/radio later). The host shows a green tag for
each channel that is **actually available** and hides the rest, so you can tell
at a glance which transports are live.

---

See also: [aprx.md](aprx.md) for the message‑level conventions that ride this
transport, and [ble.md](ble.md) for the off‑grid transport that the iGate bridges
to.
