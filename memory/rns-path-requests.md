---
name: rns-path-requests
description: RNS path requests (pull path-finding) implemented + validated — reaches peers whose announce never passively flooded in
metadata:
  type: project
---

Implemented RNS **path requests** (the pull half of path-finding) in
`reticulum-dart` `RnsTransport.requestPath(destHash)` + `RnsService.requestPath`
/`hasPathTo` + API `POST /api/rns/requestpath {dest}` / `GET /api/rns/haspath?dest=`.

**Wire format (interop-verified vs reference RNS 1.3.5):** a HEADER_1 BROADCAST
DATA packet to the PLAIN destination `rnstransport.path.request`
(hash `6b9f66014d9853faab220fba47d02761` = truncated_hash(name_hash)), data =
`destHash(16) + ourTransportId(16) + randomTag(16)`. A peer (or a hub the target
is a local client of) answers with the target's announce tagged
`context = PATH_RESPONSE (0x0B)`, which existing `ingest()` learns as an ordinary
announce (also now flood-budget-exempt). No responder code needed — the public
hubs already answer.

**Validated live 2026-06-22:** TANK2 and C61 on different networks could NOT see
each other's announces all session (passive flooding over the community hubs
fails; `rns.beleth.net`, the intended relay, is DOWN). After
`POST /api/rns/requestpath` for C61's dest, TANK2's log went from **0** mentions
of C61 (whole session) to showing C61's dest + a usable path (`hasPathTo` true).
So path requests restore reachability where passive announce flooding doesn't.

**Why it matters:** this is the foundation for reliable device-to-device
(addressed delivery / links / LXMF / files) on busy or asymmetric public hubs.

**Validated end-to-end (member-sync transport), 2026-06-22:** `RnsService.sendLxmf`
now auto-path-requests when it has no path to the recipient (12s wait), and
`LxmfRouter` path-requests an unknown message SOURCE so it can resolve the
sender's identity and verify the signature (new `requestPath` callback). Live:
**TANK2→C61 LXMF delivered + signature-verified** over the internet between two
phones that never saw each other passively (`POST /api/rns/lxmf/send`; C61 log:
"unknown source — requesting its path to verify" → "verified, delivering" →
inbox=1). So LXMF direct = the working transport for circle member sync.

**SOLVED via store-and-forward (2026-06-22):** added a cooperative peer-mailbox
to `LxmfRouter` — a message that can't be delivered DIRECTLY is held
(`_mailbox`, keyed by recipient delivery hash) and served when that recipient
PULLS it over a link IT initiates (`pullFrom` → peer's `lxmf/propagation` dest;
contexts 0x10 req / 0x11 msg / 0x12 end). The node announces its propagation
dest; `RnsService.pullLxmf` + `POST /api/rns/lxmf/pull {dest}` + status
`lxmfPropDest`. **Validated live:** C61→TANK2 direct failed → C61 stored it →
TANK2 pulled from C61's propagation dest → verified (via source path-request) →
TANK2 inbox=1. So BOTH directions now work between the two phones despite TANK2's
broken inbound: TANK2→C61 direct, C61→TANK2 store-and-forward+pull. This is the
full cooperative member-sync transport.

**Superseded note (was the open issue):** C61 holds a path entry to
TANK2 (`hasPath` true) but its link request never reaches TANK2 (TANK2 log shows
no link activity), so `sendLxmf` returns false. TANK2→C61 works fully. This is
TANK2's persistent INBOUND asymmetry on its current network — the path entry's
next-hop hub doesn't actually forward addressed packets to TANK2 (same root as
the all-session announce-invisibility). Likely needs: TANK2 on a better network,
OR path-quality validation / multi-next-hop retry, OR LXMF propagation-node
(store-and-forward) delivery so the recipient PULLS instead of being pushed to.

**Key limitation for circles:** circle datagrams ride *broadcast announces*
(`hal_rns_broadcast`), which do NOT use paths — so they still don't cross
(RXDG diagnostic stays empty). Making circles reliable needs ADDRESSED delivery
over these paths (the link transport the user asked for). The hard remaining
piece is short-code DISCOVERY: a joiner with only `5cc-d08` can't derive the
owner's RNS dest, so discovery needs a directory (the social relay) or a
short-code-derived rendezvous — path requests alone don't solve discovery.
See [[circles-internet-test-state]] [[rns-passive-mode-and-wapp-priority]].

## END-TO-END SUCCESS (2026-06-22) — corrected understanding
The "broken inbound / change network / dedicated hardware" conclusion was WRONG.
Reticulum routes fine between two NAT'd phones via the public hubs. Two real
bugs were hiding it:
1. **Path quality + timing**: addressed delivery (incl. large RESOURCES) works
   TANK2<->C61 once a path is established (path request). Earlier failures were
   the send firing before the path landed (it then stored-for-relay).
2. **THE root bug: `_writeStr`/`_writeUtf8` in wapp_engine.dart did NOT
   NUL-terminate** the wasm buffer. The circles keyset signature is read with a
   strlen-based `s_len()` into a STACK buffer (`char sig[160]`), so it ran past
   the 128-hex sig into stack garbage (measured 189 vs 128), corrupting the
   datagram JSON -> C61 got a truncated sig -> `KS:sig-fail`. Static zero-init
   buffers happened to work, hiding it; the native test mocks crypto so never
   caught it. Fix: NUL-terminate in `_writeStr`/`_writeUtf8`.

VALIDATED LIVE, two NAT'd phones, real public Reticulum, no hardware/network
change: C61 joined "Gossip Test" by addressed keyset (sig verified), got the
epoch key (addressed keyreq stored -> TANK2 pulled it -> sent key back), posted
a message that reached TANK2 via cooperative store+pull (rx datagram 244B), and
received TANK2's pushed reply. Full bidirectional cooperative member sync works.
Public LXMF propagation nodes are also visible on the net (future store-forward).
