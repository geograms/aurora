# BLE Street Mesh — design & implementation plan

Status: **approved design, not yet implemented**
Scope: street / small-village scale (100s of phones), text messages and small
bursts, no infrastructure. Cellphones are the primary devices; battery matters.
Owner planes: Aurora host (BLE bus, GATT, storage) + Chat wapp (routing logic,
gossip, APRS semantics).

---

## 1. Problem

Today's BLE-for-APRS is a 1-hop digipeater flood: every station that hears a
message re-airs it once (`wapps/chat/main.c` `rq_push`, dedup rings). Cost per
message is O(N) transmissions — at 100 devices in range, ~100 rebroadcasts of
*every* message, all contending for each phone's single advertising set. The
compact wire format has no hop/TTL field; loop control is only content-hash
dedup. This cannot scale to a crowded street.

Goal: any two people within ~6 BLE hops can exchange messages reliably, with
messages surviving devices that move out of range and return later, while the
radio stays quiet enough to actually work in a crowd.

## 2. Constraints (measured from the codebase, keep in mind throughout)

| Constraint | Value | Where |
|---|---|---|
| Advertising sets per phone | 1, multiplexed round-robin | `Ble5.kt` (`ROTATE_MS=1200`) |
| Distinct frames a phone can present | ~0.83/s | same |
| BLE5 extended advert payload | ~450–500 B usable | `ble5_bus.dart maxFrame=450` |
| Legacy advert payload | 31 B (~42 with scan-rsp); 13–17 B/chunk | `ble_reassembler.dart` |
| Primary advertising channels | 3 (37/38/39), no CSMA — collisions rise with density | BLE spec |
| GATT (point-to-point) | MTU 512, auto-pair transient link exists (FFE0/FFF1/FFF2); hops 37 data channels w/ AFH | `Ble5.kt`, `ble5_bus.dart` |
| GATT concurrency | ~4–7 practical; connect costs 1–2 s | Android reality |
| Connectable advertisers | scarce — extended broadcast set must stay NON-connectable (status-147 starvation); GATT discovery uses the separate legacy connectable beacon | `Ble5.kt` |
| Android scan behaviour | batched bursts, gaps tens of s to ~2 min; ~5 scan-starts/30 s throttle; unfiltered (company-id 0xFFFF demux in software) | `ble_service_io.dart` |
| Devices that can't extended-advertise | scan-only leaves (e.g. C61) — can hear + GATT-dial out, can't beacon | `Ble5.kt isSupported()` |
| Battery | scanning dominates drain, advertising is cheap | Android reality |

Two consequences drive the whole design:

1. **Radio is scarce, storage is free.** Multicast only tiny control traffic at
   a low, load-adaptive rate. Bulk data moves over GATT unicast, which uses the
   37 frequency-hopped data channels — most robust exactly when the street is
   crowded, which is when the 3 primary advert channels collapse.
2. **Hearing is eventual, not instant.** Any per-advert signal can be missed
   for up to ~2 min. All reachability must integrate over tens of seconds;
   delivery must tolerate per-hop latencies of seconds to tens of seconds
   (6 hops ≈ 30 s–3 min end-to-end — acceptable for messaging, absorbed by
   store-and-forward).

## 3. Architecture — two planes

### Plane 1: Gossip (connectionless broadcast, control only)

Each advertising-capable node airs a periodic **route beacon** on the shared
BLE5 bus (new subtype, e.g. `0x4D` MESH, alongside 0x41 APRS / 0x55 RNS / 0x47
presence). It carries *only* control state — never message payloads:

```
[ver1][callsign≤9][cond1][class1][ dv: (hash3, cost·4bits)×K ][ have: bloom ]
```

- **callsign** — sender, plain (same identity as APRS/chat).
- **class byte** — device type, self-declared: phone / tablet / computer /
  router-hub / ESP32-dongle / base-station appliance / other. Shown in the
  Bluetooth wapp (§12) and an input to custodian scoring (a router or dongle
  is stationary and powered by definition; a phone is not).
- **cond byte** — node conditions:
  - bit 0: powered/charging → may scan continuously, accept many GATT sessions
  - bits 1–3: uptime, log bucket (<10 min … >3 days) → stability
  - bits 4–5: mobility: stationary / semi / moving (position variance over
    ~30 min via existing GPS HAL, or significant-motion) → base-station signal
  - bits 6–7: storage headroom bucket → custodian eligibility
- **dv digest** — distance-vector routing table export: 3-byte callsign hash +
  4-bit cost per entry (~3.5 B/entry → ~110 destinations per 450 B advert; a
  200-node village = 2 rotating beacon frames). 2-byte hashes collide too often
  at this scale (~30% birthday at 200 nodes); 3 bytes makes collisions
  negligible.
- **have digest** — small rotating Bloom filter (~128 B) of `am` message ids
  this node has *received* recently. Purge signal for store-and-forward (§6).

Beacons supersede (one bus key, latest wins) — never queue-flood.

### Plane 2: Data (GATT unicast, per-hop custody)

Messages move node→node in **short auto-paired GATT sessions** (<5 s,
serialized) to the chosen next hop. Custody transfer per hop:

```
open GATT → hand over queued message(s) for/via that peer → in-session ack
→ custody transferred; my copy demotes to archive
```

One session flushes *everything* pending for that neighbor: messages in
transit, parked mail for targets it reaches, receipts, and (see below) a full
gossip exchange. The auto-pair GATT path already exists (the >450 B size-router
branch); it needs a mesh service channel on top.

**GATT peering (two-tier gossip):** whenever two nodes connect anyway, they
also swap full neighbor tables, contact histories, and have-digests — far
richer than what fits in adverts. Adverts carry the compressed digest; peering
carries the full map.

Broadcast **cost-gradient forwarding** (re-air only if strictly closer to the
target, TTL-limited) is retained only as a *fallback* when GATT to the chosen
next hop fails repeatedly.

## 4. Routing — lightweight distance-vector

Classic RIP-style DV with the standard guards, seeded by the beacons:

- **Learn:** for each `(dest, cost)` in a neighbor N's beacon: if
  `cost+1 < myCost[dest]` → route `dest → via N, cost+1`.
- **Hop cap 6.** Cost is 4 bits; 7 = infinity. Kills count-to-infinity fast and
  matches street geometry (~1 km at 50–100 m per hop).
- **Split horizon:** never advertise a route back to the neighbor it came from.
- **Bidirectional check:** N is usable as next-hop only if N's beacon lists
  *me* among its neighbors (asymmetric links are common on BLE; a one-way
  neighbor is a black hole). Free to verify — the digest carries it.
- **Aging:** a route expires when its via-neighbor's beacon goes silent past
  the reach window (reuse `REACH_WINDOW`-style aging, integrate over ≥60 s to
  ride out scan gaps).
- **Triggered updates:** beacon immediately (subject to politeness, §7) when a
  route changes; otherwise periodic.

Per-neighbor **contact ratio** is tracked continuously: fraction of recent
hours the neighbor's beacon was heard (EWMA per hour-bucket). Input to
custodian scoring (§6).

## 5. Node roles

Roles are emergent from the condition byte — no manual configuration:

- **Leaf** (default battery phone, and all scan-only devices): hears gossip,
  originates/receives, dials GATT outbound. Doesn't relay broadcast, minimal
  beacon (presence only when battery-constrained).
- **Relay:** advertising-capable node with headroom; exports DV digest, accepts
  custody transfers.
- **Base station:** powered + stationary + long uptime + storage headroom. The
  street's natural mailboxes (a plugged-in shop tablet, not a passing
  pedestrian). Scan continuously, accept more concurrent GATT sessions, act as
  preferred custodians. Score is computed by *others* from the beaconed
  condition byte — self-claims only raise how often you're *chosen*, not what
  you can see (limits abuse until beacons are signed, §9).

## 6. Store-and-forward (SCF)

Every custody node archives what it carries. Persistent sqlite store (must
survive restarts — 7-day retention outlives any process):

```
mesh_store(am TEXT PK, target TEXT, sender TEXT, wire BLOB, ts INT,
           size INT, prio INT, state INT)   -- state: in-transit | archive
```

- **Quota: 7 days OR 100 MB, whichever first.** TTL sweep drops >7-day rows;
  above 100 MB evict oldest-first (then lowest-prio). At ~200 B/message the
  quota holds ~500 k messages — for text it is effectively TTL-bound. SCF
  carries messages and small bursts only; large media stays sender-side or
  goes via the internet edge-bridge.
- **Custodian selection** when the target is currently unreachable: hand the
  message via GATT to the reachable node with the best
  `contactRatio(target) × stability(powered, uptime, stationary)` — the node
  that most often sees the target, weighted by how likely it is to still be
  there. Replicate to the top 1–2 custodians, bounded by their advertised
  storage headroom.
- **Delivery on return:** custodians watch beacons; when the target (or a
  route to it) reappears, deliver via GATT. Only the best-scored/cost-1
  custodians initiate (hash-staggered) — everyone else waits for the purge
  signals.
- **Purge — never resend what was already received** (three layers):
  1. **In-session GATT ack** — custody transfer is confirmed inside the
     session; sender's copy demotes to archive immediately.
  2. **Live `?ACK <am> d`** end-to-end receipt (already built and validated on
     hardware) rides the gossip plane — every archiver in earshot purges that
     `am` at once.
  3. **Have-digest** in the target's beacon — any custodian that missed the
     ack (was away, archived off-path) purges matches and *skips sending*
     anything already in the target's have-set. Bloom false positives only
     suppress an occasional resend, which end-to-end retransmit covers.
- **End-to-end reliability:** unchanged receipts semantics (`am:` correlation
  id, ✓ sent / ✓✓ delivered / ✓✓ read). No delivered-ack within timeout →
  retransmit along the current route or re-park with a custodian.

## 7. Politeness — don't jam the street

Load-adaptive backoff, same shape as the RNS transport's proven auto-passive:

- Each node counts distinct adverts/s heard in a sliding window.
- **Quiet:** beacon every ~30 s (topology changing) stretching to 2–5 min
  (stable/idle).
- **Busy:** stretch beacon interval further, defer forwards with
  load-proportional stagger (generalize the existing `1+(h%3)` s digipeat
  stagger).
- **Saturated:** presence-only minimal beacon; hold everything else. Powered
  base stations back off *last* (they're the useful chatter); battery phones
  go quiet *first*.
- Battery scan policy: charging/screen-on → continuous scan; on battery in
  background → balanced/opportunistic scan (bigger miss window — SCF absorbs
  it). Reuse the existing foreground-service hold.

## 8. Privacy

Custody nodes hold messages for up to 7 days, so carried content must not be
readable by carriers:

- Encrypted 1:1 (ENC1, already built) — carriers hold ciphertext. Fine.
- **Key-unknown 1:1: encrypt-or-don't-carry.** Do not park plaintext 1:1 on
  strangers' phones; hold at the sender until the target's key beacon arrives
  (key beacons already propagate), then encrypt and hand off.
- Public geochat/bulletins are public by definition — carried as-is.
- Gossip metadata (who hears whom) is inherently visible; equivalent to what
  any passive scanner already learns today.

## 9. Trust (staged)

- M1–M3: unsigned beacons. A malicious node can advertise false routes/
  conditions and black-hole traffic. Accepted for rollout; mesh is cooperative.
- M4: **Ed25519-signed route beacons** (pubkey-beacon infrastructure already
  exists) — a node cannot forge routes or a base-station identity it doesn't
  own. Costs ~64 B + one verify per beacon.

## 10. What is reused (don't rebuild)

| Existing piece | Role in the mesh |
|---|---|
| `Ble5Bus` shared advert set + subtype demux | gossip plane carrier |
| Auto-pair GATT (size-router >450 B path) | data plane carrier |
| Legacy connectable discovery beacon | GATT reachability (extended set stays non-connectable) |
| `?HELLO` + `g_sdev` seen-device registry | seed for neighbor table + contact ratios |
| `am:` + `?ACK d/r` receipts (validated) | end-to-end acks + SCF purge |
| `mailbox_add` / `?MAIL` | conceptual ancestor of SCF (replaced by sqlite store) |
| Dedup rings (`fseen`/`rpt`) | fallback broadcast path loop control |
| RNS auto-passive pattern | politeness backoff shape |
| Reticulum internet edge-bridge | off-street reach (unchanged; the on-street mesh replaces RNS *BLE* transport plans) |
| GPS HAL / position | mobility classification |

## 11. What changes where

**Host (aurora):**
- `lib/connections/bluetooth/`: MESH subtype on the bus; mesh GATT service
  (custody transfer + peering exchange protocol); beacon assembly/parse.
- New `lib/services/mesh/`: DV table, contact-ratio tracker, custodian scorer,
  politeness governor, sqlite SCF store (quota sweep), have-digest bloom.
- HAL: expose mesh send/receive + route/neighbor queries to wapps (keep host
  generic — mesh is a transport service, chat semantics stay in the wapp).

**Chat wapp (`wapps/chat`):**
- Replace the blind BLE digipeater for 1:1 with mesh routing (send → host mesh
  service). Keep the broadcast path for geochat bulletins + as gradient
  fallback.
- TTL byte in the compact wire format (foundational even for the fallback).
- Read receipts / `?ACK` unchanged.

**Bluetooth wapp (`wapps/bluetooth`, new):** devices/mesh/settings UI (§12);
owns the mesh preferences (quota, retention, roles, battery, politeness).

**ESP32 (later):** dongles can join as fixed base stations (always powered,
stationary by definition) — out of scope for M1–M3.

## 12. Bluetooth wapp

A new **Bluetooth** wapp (`wapps/bluetooth`), the mesh's face — same pattern as
the Reticulum wapp (observed-only registry surfaced by the host, native
rendering, no webview, layout off the UI thread):

**Devices view** — everything within reach, live from the gossip plane:
- Per device: callsign, **device-type icon** (phone / tablet / computer /
  router / ESP32 / base station / other, from the beacon class byte),
  condition chips (⚡ powered, uptime, 📍 stationary/moving, storage headroom),
  hop count/cost, last-heard recency, contact ratio, link quality (RSSI,
  bidirectional-confirmed or one-way), and current role (leaf / relay / base
  station).
- Tap a device → detail panel: its advertised DV digest (who *it* reaches),
  neighbors in common, SCF state (messages we hold for it / it holds for us).
- **Actions**: send message (opens the existing 1:1 chat for that callsign),
  ping/reach-test, "prefer as custodian", forget.

**Mesh view** — street-level picture: neighbor graph (nodes = devices with
type icons, edges = confirmed links weighted by contact ratio), channel-load
meter (adverts/s heard → the politeness governor's input, §7), and counters:
routes known, messages in transit / archived, store usage vs quota.

**Settings** — the mesh's preferences live HERE (host mesh service reads them;
single source of truth):
- SCF retention: max age (default **7 days**) and store quota (default
  **100 MB**), current usage + a purge-now action.
- Device class override (auto-detected from platform, user-correctable — e.g.
  a plugged-in tablet on a wall declares itself a base station).
- Role cap: allow/deny base-station promotion; relay on/off (leaf-only mode).
- Battery policy: scan aggressiveness on battery (balanced / opportunistic),
  beacon interval bounds.
- Politeness thresholds (advanced): busy / saturated adverts-per-second cutoffs.
- Privacy: encrypt-or-don't-carry toggle (default on, §8).

Host stays generic (mesh service exposes registry/stats/prefs via HAL; all
Bluetooth-specific presentation lives in the wapp) — same split as the
Reticulum wapp.

## 13. Milestones

- **M1 — see the street.** Condition/class-byte + DV beacon, neighbor table,
  bidirectional check, contact tracking, and the **Bluetooth wapp devices
  view** (it doubles as M1's verification instrument). 3 phones: each shows
  correct 2-hop routes, conditions, device types. No data plane yet.
- **M2 — move a message.** GATT custody transfer + sqlite SCF + in-session
  ack + `?ACK` purge + have-digest; wapp gains actions (send message, ping)
  + SCF counters. 3 phones in a line (A–B–C, A and C out of range of each
  other): A→C delivers via B; C offline → parks at B → delivers when C
  returns; verify no duplicate delivery after return.
- **M3 — behave in a crowd.** Base-station scoring, custodian selection,
  politeness backoff, battery scan policy, broadcast fallback; wapp settings
  (quota/retention/roles/battery/politeness) + mesh view with channel-load
  meter. Soak test: all available devices + ESP32 scanners measuring channel
  load.
- **M4 — harden.** Signed beacons, encrypt-or-don't-carry for key-unknown 1:1,
  quota tuning, village-scale field test.

Validation rules that apply throughout: device tests on different networks
where reachability claims are made; never trust a single scan burst; measure
airtime (adverts/s heard) before/after — the whole point is that the number
stays flat as N grows.
