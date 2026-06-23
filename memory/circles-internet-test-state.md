---
name: circles-internet-test-state
description: Resume point for the two-phone circles-over-Reticulum internet test (paused 2026-06-22 night)
metadata:
  type: project
---

Two-phone (TANK2 owner / C61 joiner, different networks) circles-over-internet
test, **paused late 2026-06-21/22, to resume when the user writes back**.

**Done & verified:** Step 1 live on TANK2 — circle "Tank Squad"
(circleId `5ccfc38b202606b468d7313de45fa92d63af532ee8c124e0ba4f430dbfeeed08`,
short code **5cc-d08**), 3 AES-256 messages; at-rest DB confirmed
ct=ciphertext / body=plaintext / epochs.key=plaintext. Code for short-id
discovery + history sync written, native-tested, deployed (circles wapp 0.12.0).
See [[circles-wapp]], [[rns-passive-mode-and-wapp-priority]],
[[c61-budget-phone-release-only]].

**Blocked at Step 3:** C61→TANK2 announce propagation fails over the public mesh
(stable: TANK2 never receives C61; C61 receives TANK2). Both meshed to shared
hubs (wisco/sydney/birdsnet); TANK2's inbound announce reception ~half C61's.
NOT a circles-code bug. User's chosen direction: **disabled BLE on both phones**
(`settings put global bluetooth_on 0`, both = 0 now) to remove BLE as a variable;
BLE optimization deferred. APRS bg wapp was the CPU hog on TANK2 (100%→0% when
stopped; BLE-off alone didn't fix it — APRS also does APRS-IS/GPS work). APRS bg
stopped on both for testing.

**Current device state (USB/adb):** TANK2=`TANK200000007933` (callsign X16WMN,
profile dir `X16WMN`, now on RELEASE build, no run-as), C61=`C61000000004616`
(X1RTP2, RELEASE). Bluetooth OFF both. Drive via `adb forward tcp:<L> tcp:3456`
+ `/api/wapp/{start,cmd,tick}` and `/api/rns/status`. Circle DBs:
`run-as`-only (release → no run-as now; verify via API outbox / a debug build if
DB reads needed). Don't reboot the phones.

**TEMP diagnostic to remove before finalizing:** `circle_on_datagram` in
`wapps/circles/circle.c` has a `notify("info","RXDG:"+k)` line marked `/* TEMP
diag */` — and TANK2's installed wasm is a hot-swapped diagnostic build. Rebuild
clean (remove RXDG) + repackage before shipping.

**RESOLVED root cause + foundational fix (2026-06-22):** passive announce
flooding fails C61↔TANK2 over the community hubs (beleth, the real relay, is
DOWN). Implemented + VALIDATED RNS **path requests** (pull path-finding) — see
[[rns-path-requests]]. After a path request, TANK2 reaches C61 where it never
could before. This makes LXMF/files/addressed delivery work phone-to-phone.

**Agreed direction = cooperative member-to-member sync (user-confirmed):**
circles are hosted by ALL members, not the admin — discovery/history/sync must
work through ANY online member; the owner is only needed to SIGN membership
changes (master key). Build order chosen: **member-to-member sync FIRST**.

**Design for member-to-member sync (next build):**
- Transport = Aurora's **LXMF direct delivery** (already wired:
  `identityForDest: pathFor(h)?.identity` — now resolvable via path requests).
  Route circle datagrams as addressed LXMF to each online member's RNS dest
  (path-request the dest first). Store-and-forward via LXMF propagation nodes is
  a FOLLOW-UP for offline members (LXMF currently direct-over-link only).
- **Address book**: members need npub→RNS-dest. Add `rns_dest` to the `members`
  table; bootstrap by the owner addressing the keyset (carrying every member's
  RNS dest) to members at join/membership-change; thereafter members gossip
  among themselves with no owner.
- **Gossip**: circle_send / history(rq) / keyset deliver ADDRESSED to known
  member dests + re-gossip received events, so any online subset converges.
- Then layer DISCOVERY (relay directory: any member publishes
  shortcode→{fullId,dest}; joiner queries + reaches any online member; join
  request held until an admin signs).

**Auto path-request still TODO**: wire the app to auto-`requestPath` when an
addressed send has no path (so LXMF/files/circle-sync self-heal without manual
API calls). `/api/rns/requestpath` + `/api/rns/haspath` exist for now.

**Device state:** both phones on RELEASE build, BLE OFF, APRS bg stopped. Circle
"Tank Squad" + "Gossip Test" (id d96ba6a5…, C61 added as member) persist on TANK2.

## Gossip layer BUILT (2026-06-22) — see [[rns-path-requests]]
Member-to-member cooperative sync is implemented end-to-end:
- Host HAL `hal_rns_send_to` / `hal_rns_pull` / `hal_rns_delivery_dest` /
  `hal_rns_prop_dest` (wapp_engine) → RnsService `wappSendTo`/`wappPull`, routing
  inbound wapp-marked LXMF (field 0xB0) into `_wappInbox`. Generic, any wapp.
- LXMF store-and-forward now serves LARGE messages as a batched RESOURCE
  (`_packBatch`/`_unpackBatch` in lxmf_router; was single-packet only).
- circles: `members.deliv/prop` address book; keyset carries each member's
  dl/pp; circle_send / broadcast_keyset / send_wrapped_key deliver ADDRESSED
  (hal_rns_send_to) + broadcast fallback; circle_tick `pull_from_members`.
  Bootstrap helper `circle_add_member_dests` + `whoami` command + circles 0.13.0.
  Native tests pass; deployed.

## HARD LIMIT hit = TANK2's network (environmental, NOT code)
Precise directional diagnosis from the live test:
- TANK2 **cannot receive a FRESH inbound link request** — so C61 (or anyone)
  CANNOT initiate a link/pull TO TANK2. Only TANK2-initiated links work
  (responses ride the reverse path TANK2 opened).
- Multi-round-trip RESOURCE transfers (large messages) through TANK2's inbound
  are unreliable even when TANK2 initiates (the C61→TANK2 part-requests/proofs
  die). So: SMALL single-packet pushes TANK2→C61 work; TANK2-initiated pulls of
  small batches from C61 work; but the LARGE keyset can't bootstrap C61 (push =
  flaky resource; pull = C61 can't initiate to TANK2).
- So the gossip stack is correct but the live demo is blocked by TANK2's broken
  inbound. **Recommended: put TANK2 on a normal network** to validate the full
  stack (everything else is built + unit-tested). Alt software fix: chunk large
  circle datagrams into independent single packets (avoid resources).

**TODO cleanup:** remove the TEMP `RXDG:` notify in `circle_on_datagram`
(circle.c) before shipping — it spams notifications.
