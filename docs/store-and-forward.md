# Store-and-forward

A message to a station that no path reaches is handed to a nearby device, which
carries it and delivers it on meeting the recipient. Any capable device can act
as a carrier: a phone, a tablet, or an ESP32 dongle.

This is a core service. No wapp participates: a wapp sends a message and is
called back when one arrives ([architecture.md](architecture.md)).

Implementation: `lib/services/mesh/mesh_courier.dart` (decision, transmission,
ingest), `mesh_custody.dart` (taps), `mesh_store.dart` (parked mail database),
`esp32/components/geogram_blemesh/blemesh_scf.c` (ESP32 side).

---

## 1. Determining that no path exists

Every reachability test available before transmission returns an incorrect
answer. Both were measured against a device with both radios switched off:

| Test | Result returned | Cause |
|---|---|---|
| `hal_rns_nodes`, observed-node list | recently seen | a hub replays its entire announce cache on link-up, timestamping every node it has ever heard |
| transport `hasPath(dest)` | path present | a learned Reticulum path outlives the station that taught it by hours |

Delivery is the reliable signal. A station on the LAN, or reachable through a
hub, acknowledges in well under one second.

```
sendLxmf(dest, text)
  MeshCourier.armLxmf(dest, text)      unconditional
  after 20 s:
    lxmfPendingFor(dest) == 0   delivered, discard
    lxmfPendingFor(dest)  > 0   no path, transmit a carried copy
```

The interval is 20 seconds because `sendLxmf` abandons a direct link at 10
seconds, so the send has definitively failed rather than merely not yet
succeeded. After 15 minutes the courier releases the message to the ordinary
retry ladder.

## 2. Wire format

```
FROM 0x1F TO 0x1F am:<6hex> [sd:<32hex>] <body> [~<sig>]
```

This is the wire as implemented. [XPRS.md](XPRS.md) specifies a different one,
in which the same information is carried as `key:value` fields and a carrier
appends itself to `via:` rather than the frame being rewritten. The behaviour
described in this document is unaffected; only the encoding of the frame
changes. XPRS.md section 36 tracks the gap.

`FROM` and `TO` are always public. A carrier that cannot read the recipient
cannot determine where to relay the frame, which is what allows custody to
operate between stations that do not trust each other.

`am:` is the receipt identifier and is always first. Both custody layers, the
phone's `MeshCustodyDelegate.onAirFrame` and the ESP32's `blemesh_scf_offer`,
read it at a fixed offset. A frame without one is carried but cannot be handed
over within a session.

`sd:` is the sender's LXMF delivery address, allowing the receiver to key the
conversation by identity. Without it a carried message can only be keyed by
callsign, and a callsign-keyed conversation is not renderable.

The body is `ENC1:<base64url>` sealed to the recipient's key when one is known,
and plaintext otherwise. Refusing to transmit without a key would leave the
message undeliverable, and the envelope is public in both cases.

`~<sig>` is a short-Schnorr signature over `sha256("<FROM>|<text preceding the
signature>")`, base85 encoded. It is verified on arrival when the sender's key
is known, since a carried message has passed through stations outside the
sender's control. Unsigned mail and mail from unknown keys are still delivered,
as most stations have not published a key.

There is no `np:` recipient token. It consumes 66 of the 240 available bytes and
establishes nothing that a sealed body does not, since only the holder of that
key can open the body.

The limit is 240 bytes. Larger frames are refused with a logged reason. See the
budget table in [ble5.md](ble5.md).

## 3. Transmission

Carried copies are transmitted through `BleService.enqueueAdvert`, the same path
used by a wapp broadcast, so the custody tap parks the local copy exactly as it
parks a frame from another station.

Each copy is transmitted three times: at 0, +90 s and +180 s, with a 300 s TTL.
A receiver scans in bursts, so a single advertisement window is unreliable: in
one measurement an ESP32 two metres away parked six frames from one run and none
from the next.

## 4. Carrying

Any device that receives a direct frame addressed to another station parks it.

Mail is stored for any recipient. A carrier that holds mail only for stations it
already knows is of no use to a station that is out of range of everyone.
Prioritisation occurs under storage pressure rather than at admission. Each
parked frame carries an urgency, and the quota sweep evicts in
`ORDER BY urg, ts`:

| `urg` | Given to |
|---|---|
| `low` | a stranger's mail, when the frame states nothing |
| `normal` | mail we originated, or whose target is inside the mesh horizon |
| `high` | the most a stranger's frame may claim |
| `urgent` | ours only |

The four levels are XPRS `urg:` ([XPRS.md](XPRS.md) section 13.5), so a level
stated on the wire needs no translation. **A sender states what it wants and the
carrier decides what it may have**: a stranger's frame is capped below `urgent`,
because stations will mark everything urgent and no device should be able to
push its host's own traffic out of its host's own store.

Storage is bounded at 100 MB or 7 days, whichever is reached first, with
`maxWire` of 480 bytes per frame and `inTransitMax` of 4000 in-transit rows, so
that a busy location cannot fill the disk with mail the device may never
deliver. Local mail is never refused.

[XPRS.md](XPRS.md) section 31.3 cites this policy as the model of a decision the
format deliberately leaves alone: it states no retention period, no minimum and
no eviction order, because a dongle with a microSD card and a home server with a
spare terabyte cannot share one number. The 100 MB, the 7 days and the
`ORDER BY urg, ts` above are this implementation's answer and nobody else's, and
changing them breaks no specification.

Groups, observations, `?` control frames and receipts are never carried.

That covers the closed groups of [XPRS.md](XPRS.md) section 26 as well. An `X5`
group callsign is addressed like a station but is group traffic, and custody is
not how a roster travels: section 26.8 propagates membership by members
rebroadcasting the signed grants they already hold, which needs no carrier
because every grant verifies against the group's key on its own.

The ESP32 implements the same behaviour in 24 slots (`BLEMESH_SCF_MAX`) at 252
bytes per frame, persisted to `/sdcard/mesh/pending.bin` so that a power cycle
does not discard parked mail.

### 4.1 Carrying toward a place, which is not implemented

Everything above carries mail to a **callsign**: a carrier holds a frame until it
meets the station it is addressed to. That works when the two are in the same
region and never completes when they are not, because nothing tells a carrier
which direction helps.

[XPRS.md](XPRS.md) sections 13.4 to 13.10 specify the missing half. A packet
carries `dest:` (where it is bound) and `near:` (how close counts as arrived),
and a carrier accepts a copy **only if it expects to reduce the distance to
`dest:`**. That single rule turns custody from "wait until I happen to meet you"
into a route across a continent, moved by people going that way anyway.

The parts of it this document already provides, and which do not change:

- the quota and eviction policy above, which is why XPRS specifies no copy limit
- `via:`, which prevents a carrier taking the same packet twice
- release on receipt, section 6

The parts that are specified and not built:

| Element | Status |
|---|---|
| `dest:` and `near:` on a carried packet | not implemented; custody is keyed on callsign only |
| the closer-to-destination admission rule | not implemented; admission is currently "park anything for anyone" |
| `urg:` as the eviction key | **implemented**; four levels, capped per source, `ORDER BY urg, ts` |
| `until:` as a carry deadline, capped at a year | not implemented; the 7-day quota is the only bound |
| regional delivery, `dest:` with no recipient | not implemented |
| `route:` copied into a signed receipt | not implemented |
| `t:mailbox`, a recipient's preferred carriers | not implemented; nothing records who tends to see a given station |
| several mailbox declarations, selected by `since:` and `until:` | not implemented; there is no store to select from |
| `scope:local`, which must never be carried | not implemented; everything offered is a candidate |

Two of those rows change what this document says about admission, so they are
worth naming rather than leaving in a table.

**`t:mailbox` is the half of routing this document does not have.** Section 4
carries mail for anyone, which is right, and then has nothing to say about
*which* carrier is likely to succeed. A mailbox declaration is the recipient
saying so themselves: these stations tend to see me, try them first. It is
signed, and a carrier that cannot verify one must ignore it, because a forged
mailbox declaration collects somebody else's mail from every polite sender.

A station may have several in force at once, so this is a query against time
rather than a single stored value ([XPRS.md](XPRS.md) section 13.12.1). Each
declaration may carry `since:` and `until:`; one without them is open-ended.
Delivering to a recipient means picking the declaration whose window contains
the moment, narrowest first, and falling back to the open-ended one. An
implementation that keeps only the newest declaration per callsign gets this
wrong the moment somebody announces a month away from home in advance, which is
the case the field exists for.

A declaration is withdrawn by a signed `remove:mailbox` naming it, not by being
superseded, so a carrier holds them as a set and deletes by identifier.

**`scope:local` must be refused at admission, not at transmission.** A packet
marked local is for the bearers in range now -- Bluetooth, WiFi Direct, a LAN --
and carrying it to another town is precisely what it excludes. Parking one and
airing it later would be a leak wearing the shape of a feature, and it is the
one case where the "park anything for anyone" rule in section 4 must not
apply.

The carrier already reads `urg:` from a frame that carries one
(`MeshCustodyDelegate._urgOf`). No frame does yet, so the default holds and the
behaviour is identical to the two-level scheme it replaced: ours `normal`, a
stranger's `low`. The moment senders start writing `urg:`, carriers honour it.

## 5. Delivery

Two independent paths complete delivery.

**Re-transmission on sighting.** The carrier receives the target's beacon and
re-transmits the parked frames. The ESP32 sends at most 4 per sighting, with one
re-transmission per frame per 60 seconds.

```
SCF: X1RD89 back in range -> re-airing 4 parked frame(s)
```

**MSP custody handover.** The target opens a GATT and MSP session, the carrier
transfers every frame addressed to it, and then archives its copy.

```
custody of 7b0d6e -> X1RD89 (purged)
```

On the receiving device both paths reach `MeshCourier.ingest`, which verifies
the signature, decrypts, deduplicates by `am` or by content, and injects the
message into the LXMF inbox through `RnsService.injectLxmf`. This is the same
inbox used by directly delivered messages, so the receiving wapp renders the
existing conversation without distinguishing the delivery path.

## 6. Releasing carried copies

The recipient's `?ACK <am>` purges carriers still holding a copy. The have-bloom
in each mesh beacon covers frames the receipt did not reach. A carrier that
completes a handover archives its copy rather than deleting it, so that a
subsequently rejected handover leaves the message owned by a station.

## 7. Instrumentation

```sh
curl -s localhost:3458/api/status | jq '.mesh.courier'
# {"armed":4,"aired":4,"refusedTooLong":0,"refusedNoIdentity":0,
#  "ingested":0,"ingestDropped":0}
```

| Counter | Meaning |
|---|---|
| `armed` | direct sends the courier is tracking |
| `aired` | copies transmitted for carriage, no path existed |
| `refusedNoIdentity` | no callsign available to address a carrier |
| `refusedTooLong` | over 240 bytes, nothing transmitted |
| `ingested` | carried messages unwrapped and delivered to a wapp |
| `ingestDropped` | invalid signature, undecryptable, or addressed elsewhere |

Relevant log lines: `Courier: no path to`, `Courier: delivered a carried
message`, `Mesh: parked ... for custody`, `LXMF: carried message`.

## 8. Validation procedure

A test in which the sender remains in range proves nothing, because a direct
link explains the delivery equally well.

The following procedure was run on 2026-08-06, tablet to T-Dongle to TANK2:

1. Recipient dark: `svc bluetooth disable`, WiFi off. ESP32 store cleared with
   `scfclear`.
2. Send. `courier.aired` increases and the ESP32 logs
   `SCF: parked 129B for X1RD89 (am=...)`. Confirm with the `scf` command rather
   than the `scf=` count in `status`, which is capacity-bound.
3. Switch the sender's Bluetooth off. Only the carrier can now deliver.
4. Enable the recipient's Bluetooth. Expect re-transmission or
   `custody of ... -> ... (purged)`, the ESP32 store returning to 0,
   `courier.ingested` increasing by the number sent, `ingestDropped` at 0, and
   the messages visible in the conversation on the recipient's screen.

Result: 4 transmitted, 4 parked, 4 handed over, `ingested: 4`,
`ingestDropped: 0`, all four rendered. See [validation.md](validation.md): a log
line is not a delivered message until it appears on screen.

## 9. Limits

- Carried payloads are limited to 240 bytes. Longer messages and attachments
  wait for a direct path; the bulk lane transfers the bytes separately once one
  exists.
- A station with no known callsign cannot be addressed on an envelope. The
  courier reports `refusedNoIdentity` rather than transmitting a frame no
  carrier can route. Callsign and LXMF-address pairs are persisted in
  `rns.lxmfDirectory`, because the station requiring a carrier is by definition
  the one that has stopped announcing.
- Custody operates per frame rather than per conversation. Ordering across
  carriers is not guaranteed, and a carried message may arrive after a message
  sent later over a direct path.
