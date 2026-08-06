# Store-and-forward — delivering to someone who is not there

A message to a person no path reaches should not sit in a queue until they
happen to come back. It should be handed to whatever device is nearby and
delivered when *that* device meets them. Any geogram-capable device can carry
it: a phone, a tablet, an ESP32 dongle on a windowsill.

This is a **core** service. No wapp participates: a wapp sends a message and is
called back when one arrives ([architecture.md](architecture.md)).

Code: `lib/services/mesh/mesh_courier.dart` (decide + air + ingest),
`mesh_custody.dart` (the taps), `mesh_store.dart` (the parked-mail database),
`esp32/components/geogram_blemesh/blemesh_scf.c` (the dongle's half).

---

## 1. The decision: "is there no path?"

**Every up-front test lies**, and both were measured against a phone with both
radios switched off:

| Test | What it said | Why |
|---|---|---|
| `hal_rns_nodes` / observed-node list | "seen, recently" | a hub replays its whole announce cache on link-up, stamping every node it ever heard |
| transport `hasPath(dest)` | `path = 1` | a learned Reticulum path outlives the peer that taught it by hours |

What does not lie is **delivery**. A peer on the LAN, or reachable through a
hub, acknowledges in well under a second. So:

```
sendLxmf(dest, text)
  └─ MeshCourier.armLxmf(dest, text)        // unconditional, cheap
        … 20 s later …
        lxmfPendingFor(dest) == 0  → delivered; drop it
        lxmfPendingFor(dest)  > 0  → there is no path; air a copy
```

Twenty seconds because `sendLxmf` gives up on a direct link at 10 s: this is
"the send has definitively failed", not a guess. After 15 minutes the courier
stops caring and the ordinary retry ladder owns the message.

## 2. The wire

```
FROM \x1F TO \x1F  am:<6hex> [sd:<32hex>] <body> [~<sig>]
```

- **`FROM` / `TO`** — public, always. A carrier that cannot read the recipient
  cannot decide whom to hand it to. This is the whole reason custody works
  without anyone trusting anyone.
- **`am:`** — receipt id, and it must come **first**: both custody layers (the
  phones' `MeshCustodyDelegate.onAirFrame` and the dongle's
  `blemesh_scf_offer`) read it at the very start of the text. A frame without
  one is carried but can never be handed on inside a session.
- **`sd:`** — the sender's LXMF delivery address, so the receiving side can key
  the conversation by *identity*. Without it a carried message can only be
  keyed by callsign, and a callsign-keyed conversation is one the rail refuses
  to render — that is exactly where the first implementation dead-ended.
- **body** — `ENC1:<base64url>` sealed to the recipient's key when we hold one,
  plaintext otherwise. Refusing to send without a key would leave the message
  nowhere, and the envelope is public either way.
- **`~<sig>`** — short-Schnorr over `sha256("<FROM>|<everything before ~>")`,
  base85. Checked on arrival **when we know the sender's key**: a carried
  message passed through hands we do not control, so a bad signature is a
  forgery and stops there. Unsigned or unknown-key mail is still delivered —
  most peers have never beaconed us a key.

No `np:` (recipient npub) token: it costs 66 of the 240 bytes a carrier can
hold and proves nothing a sealed body does not, since only the holder of that
key can open it.

**240 bytes, hard.** Over that, the courier refuses and says so. See the budget
table in [ble5.md](ble5.md#3-the-size-router).

## 3. Airing

Through `BleService.enqueueAdvert`, the same pipe a wapp broadcast uses — so
the custody tap parks our own copy exactly as it parks a stranger's.

**Aired three times**: at 0, +90 s and +180 s, TTL 300 s. A receiver scans in
bursts, so a single advert window is a lottery — the same dongle two metres
away parked six frames from one run and zero from the next.

## 4. Carrying

Any device that overhears a 1:1 frame for someone else parks it.

- **Store for anyone.** A custodian that only holds mail for people it already
  knows is no use to the person who most needs one: someone out of range of
  everybody. Sorting happens under pressure, not at the door — our own mail and
  mail for a target inside our mesh horizon get `prio 1`, a stranger's gets
  `prio 0`, and the quota sweep evicts `ORDER BY prio, ts`.
- **Bounded.** 100 MB or 7 days, whichever comes first; `maxWire` 480 B per
  frame; a hard `inTransitMax = 4000` in-transit rows so a busy street cannot
  fill the disk with mail this device may never be able to deliver. Own mail is
  never refused.
- **Never carried**: groups, positions, `?`-control frames, ack/receipt lines.

The ESP32 does the same in 24 slots (`BLEMESH_SCF_MAX`), 252 B per frame,
persisted to `/sdcard/mesh/pending.bin` so a power cycle does not lose parked
mail.

## 5. Delivering

Two independent paths, either of which completes the loop:

**A — re-air on sighting.** The custodian hears the target's beacon and puts
the parked frames back on the air (dongle: max 4 per sighting, one re-air per
frame per 60 s).

```
SCF: X1RD89 back in range -> re-airing 4 parked frame(s)
```

**B — MSP custody handover.** The target opens a GATT/MSP session and the
custodian hands over everything keyed to it, then archives its copy.

```
custody of 7b0d6e -> X1RD89 (purged)
```

On the receiving device both land in `MeshCourier.ingest`, which verifies the
signature, decrypts, dedups (by `am`, else by content), and injects the message
into the LXMF inbox through `RnsService.injectLxmf` — **the same inbox a
directly-delivered message lands in**. The wapp cannot tell the difference, and
that is the design: it renders the thread it always had with that person.

## 6. Closing the loop

The recipient's `?ACK <am>` purges custodians that still hold a copy, and the
have-bloom in each mesh beacon does the same for anything the ack missed. A
custodian that hands a message on archives its copy rather than deleting it, so
that if the handover is later rejected the message still belongs to somebody.

## 7. Watching it work

```sh
curl -s localhost:3458/api/status | jq '.mesh.courier'
# {"armed":4,"aired":4,"refusedTooLong":0,"refusedNoIdentity":0,
#  "ingested":0,"ingestDropped":0}
```

| Counter | Means |
|---|---|
| `armed` | 1:1 sends the courier is watching |
| `aired` | copies handed to the mesh (no path existed) |
| `refusedNoIdentity` | no callsign to address a carrier with |
| `refusedTooLong` | over 240 B — nothing was aired |
| `ingested` | carried messages unwrapped and delivered to a wapp |
| `ingestDropped` | forged signature, undecryptable, or not ours |

Log lines worth grepping: `Courier: no path to …`, `Courier: delivered a
carried message …`, `Mesh: parked … for custody`, `LXMF: carried message …`.

## 8. Validating it honestly

The test that proves nothing: send with the recipient's Bluetooth off, turn it
on, watch the message arrive — **the sender was in range the whole time**, so a
direct link explains it just as well.

The test that proves it, run 2026-08-06 (tablet → T-Dongle → TANK2):

1. Recipient dark: `svc bluetooth disable`, WiFi off. Dongle store cleared
   (`scfclear`).
2. Send. Expect `courier.aired` to rise and the dongle to log
   `SCF: parked 129B for X1RD89 (am=…)`. Confirm with `scf` — **not** with the
   `scf=` count in `status`, which is capacity-bound.
3. **Switch the SENDER's Bluetooth off.** This is the step that makes the
   result mean something: now only the custodian can deliver.
4. Recipient's Bluetooth on. Expect re-air and/or `custody of … -> … (purged)`,
   the dongle store back to 0, `courier.ingested` up by the number sent and
   `ingestDropped` at 0, and the messages **visible in the thread** on the
   recipient's screen.

Result: 4 aired, 4 parked, 4 handed over, `ingested: 4`, `ingestDropped: 0`,
all four rendered. See also [validation.md](validation.md) — a log line is not
a delivered message until it is on the screen.

## 9. Known limits

- Carried payloads are capped at 240 B — long messages and attachments still
  wait for a real path (the bulk lane moves the bytes separately once one
  exists).
- A peer with **no known callsign** cannot be addressed on an envelope; the
  courier says `refusedNoIdentity` rather than airing something no carrier can
  route. The callsign↔LXMF-address pairs the core hears are persisted
  (`rns.lxmfDirectory`) precisely because the peer that needs a carrier is the
  one that has stopped announcing.
- Custody is per-frame, not per-conversation: ordering across carriers is not
  guaranteed, and the recipient may see a carried message after a later
  directly-delivered one.
