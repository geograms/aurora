# XPRS over ESP-NOW

Every ESP32 has this radio already. ESP-NOW is Espressif's connectionless mode:
802.11 action frames with no association, no access point and no DHCP -- a device
puts a frame on a channel and every ESP32 listening on that channel hears it.

[ble5.md](ble5.md) is the Bluetooth bearer's page and [lan.md](lan.md) is the
LAN's; this is ESP-NOW's. [XPRS.md](XPRS.md) already assigns it: `link:espnow`
is a bearer word (section 10.6.1), and section 23.7 is what to do when a pair
wants a channel of their own.

**The number that makes this a good fit:** an ESP-NOW frame carries **250
bytes**, and the longest XPRS packet is **250 bytes** (section 4). One packet is
one frame, verbatim, with nothing to fragment and nothing to reassemble. The
Bluetooth bearer cannot say that -- its advert header costs six bytes, so a
full-length packet does not fit at all.

## What this is not

**Not a hotspot, and that is the point.** A SoftAP has a client ceiling and
divides one channel's bandwidth among everyone associated to it. Nobody
associates here. The peer table needs exactly **one** entry -- the broadcast
address -- so the 20-peer limit never binds however many stations are listening,
and there is no ceiling to run into.

**Not promiscuous mode.** Broadcast frames arrive through the ordinary receive
callback; sniffing 802.11 would add nothing except CPU on the processor the
radios need. The one thing promiscuous mode would have been for arrives free:
the receive info carries **RSSI**, so this bearer reports signal where the LAN
reports nothing.

**Not Reticulum, and not the internet.** A packet here reaches the ESP32s in
range on one channel and stops.

## The wire

```
ESP-NOW broadcast to ff:ff:ff:ff:ff:ff
one XPRS packet per frame, verbatim, no header
```

Unencrypted, because broadcast always is. Authorship is `sig:` (section 9.1),
which is the answer to "who sent this" on every bearer and does not become the
transport's job here.

## Same channel, or nothing at all

**ESP-NOW rides whatever channel the WiFi station is already on.** When the
station is associated to an access point, that is the AP's channel; when it is
not, it is whatever was last set.

Two devices on different channels **hear nothing from each other, and nothing
reports an error**. `esp_now_send` succeeds -- it has no idea who is listening.
The only symptom is a `peers:` count that stays at zero, so that is the number
to look at first when a link that should exist does not.

The practical consequence: stations that share an access point share a channel
and find each other with no configuration. Stations on different access points
do not, and no amount of restarting will change it.

Moving a pair to a channel of their own -- and to the long-range PHY, which is
where ESP-NOW's range actually lives -- is section 23.7's `t:channel` invitation:
one station proposes, the other accepts on the commons, both tune away, and both
come back. That is deliberately not part of this bearer; it is a thing a pair
does *with* it.

## Not everybody at once

Identical to the LAN, and for the same reason -- every station on the channel
hears the same frame at the same instant:

| | |
|---|---|
| A packet from another bearer | waits **200-1200 ms**, chosen at random |
| The same packet heard meanwhile | the waiting copy is **dropped** |
| A packet this station composed | goes out **immediately**, with no `via:` |

That logic is not written twice: `geogram_xprsbearer` holds it once and both
bearers use it. The identifier compared is the section 5 one, which ignores
`via:` and `sig:`, so a relayed copy is recognisably the same packet.

## `scope:local` crosses to it

Section 13.11.1 lists Bluetooth LE, WiFi Direct, WiFi Aware and a local network,
and does not name ESP-NOW -- the word did not exist when that list was written.
On the channel the station is already on, ESP-NOW is plainly one of these: no
gateway, no carrying, out of range and gone. So **a `scope:local` packet may be
put on ESP-NOW.**

That ruling is about *this* use of it. Section 23.7's working channel with the
long-range PHY can reach a kilometre, which is not what `local` was protecting,
and deserves its own answer when it is built.

## Its own beacon

The station says who it is and who it hears, per bearer:

```
t:observation f:X3WWAJ link:espnow peers:1 hears:X1RD89 sig:<60 characters>
```

`link:espnow` rather than a shared reading, because section 10.6.1 is explicit
that a reading belongs to the bearer it names -- who this station hears over
ESP-NOW is not who it hears on the wire, and one figure covering both would be a
quantity nobody can act on.

## What crosses to the other bearers

Both ways, under the ordinary relay rules: a packet heard on ESP-NOW is offered
to Bluetooth and the LAN, and a packet heard on either is offered to ESP-NOW.
The bearer refuses when this station is already in `via:` or the type's hop
budget is spent (section 13.1, 13.2), so the offer is unconditional and the
decision is one place.

Measured on a T-Dongle and an M5Stack in the same room: a phone's Bluetooth
beacon reached the M5Stack over ESP-NOW with `via:X3WWAJ` on it, and the
M5Stack's own ESP-NOW beacon came back to it over the LAN. Three bearers, one
packet, one relay.

## On the hardware

| | |
|---|---|
| Component | `geogram_xprsnow`, on `geogram_xprsbearer` |
| T-Dongle-S3 | ESP-NOW + BLE5 + LAN, all three |
| M5Stack Core | ESP-NOW + LAN. An original ESP32 has **no** BLE5 extended advertising, so it can never join the Bluetooth plane |
| Cost on the dongle | ~9.7 KB of heap: free 26.8 KB -> 17.1 KB, low-water 20.0 KB -> 10.3 KB |
| Reachability | 120 of 120 with the bearer running -- the same as idle |

**Modem sleep is turned off** (`esp_wifi_set_ps(WIFI_PS_NONE)`). A station that
sleeps misses frames that arrive while it is asleep, which Espressif's own
example warns about. On a board that also runs Bluetooth this is a coexistence
decision, not only a power one -- it was measured rather than assumed, and it
cost nothing: average ping time improved, which is what an always-awake station
would do.

**The receive callback runs in the WiFi task, on core 0.** It copies the frame
into a queue and returns; the identifier (a SHA-256), the archive and the relay
decision all happen on the bearer task. Doing that work in the callback is the
mistake `esp32.md` measured at 1 of 96 pings, in the worst available place.

**No bearer task of its own.** The LAN bearer's task pumps every registered
bearer, because a second task is 5 KB of a heap that has been down to hundreds
of bytes. If no task has claimed that job, `xprsnow_start()` says so as an error
rather than letting a silent failure be discovered in the field.

## `sent=` is not `tx=`

`esp_now_send()` returns once the frame is queued, not once the radio has
finished with it, so `tx` only ever counted what this station *decided* to say.
`esp_now_register_send_cb` counts what actually left, and both heartbeats now
print `sent=<done>/<issued> fail=<n>`. `xprsnow_settle()` waits on the same
counters, which is what section 23.7 uses instead of the 120 ms delay it used to guess
with -- retuning the radio out from under an untransmitted acceptance is a real
failure and it looked exactly like the far side not answering.

The failure that made this necessary: every `esp_now_send()` on the dongle
returned `ESP_ERR_ESPNOW_NO_MEM` for four minutes while `tx=0`, and the log said
nothing, because that branch was `ESP_LOGD`. **A refused transmission is now
`ESP_LOGW`, including a full driver queue.** See `esp32.md` -- the cause was
heap, and one of the things eating it was this bearer's own receive queue.

## Watching a rendezvous: `xprsnow_set_trace()`

Between "the radio never heard it" and "it was heard and refused" no counter can
tell you which, because a frame can be lost before anything counts it: the
callback's `xprs_looks_like` byte test, a full queue, a parse that fails. With
the trace on, every drained frame prints its length, RSSI and first 56 bytes,
and the frames that never reached the queue print as a change:

    heard 107 bytes at -55 dBm: t:receipt f:X3LTSH d:X3WWAJ r:012c52 s:ack
    radio delivered 8 frame(s) (+1), 0 not XPRS (+0), 0 dropped by a full queue (+0)

`geogram_xprschan` switches it on for the length of an exchange and off again;
it is a line per packet and is not meant to be left on.

## SOLVED: the BLE controller takes the radio from an unassociated station

The pair went deaf whenever they moved to a working channel, and six causes had
already been ruled out on the real firmware. `esp32/espnow_probe` settled it:
two boards, ESP-NOW, and nothing else, driven by hand over serial so one
variable changes at a time.

| BLE controller | station | dongle rx |
|---|---|---|
| absent (no-BT build) | never associated, ch 1 | 20 of 20 |
| absent | never associated, ch 6 | 25 of 25 |
| absent | join, leave, then ch 6 | 38 of 38 |
| up, scanning | never associated, ch 6 | **1 of 36** |
| up, scan cancelled | never associated, ch 6 | **0 of 30** |
| up, `coex wifi` preference | never associated, ch 6 | **0 of 30** |
| up, idle | **associated**, ch 1 | 24 of 24 |
| stopped and deinited | never associated, ch 6 | 25 of 25 |

**With the BLE controller running, a WiFi station that is not associated
receives nothing.** Transmission is untouched throughout -- the far board heard
36 of 36 frames from a station whose own receive count was zero, which is why
this looked for so long like the other end going quiet.

Everything else follows from it:

- the calling channel works because the station is ASSOCIATED there. Association
  is what keeps the WiFi side scheduled: it has beacons it may not miss. Leave
  the access point and the coexistence scheduler has no reason to reserve
  anything, and hands the radio to Bluetooth.
- section 23.7 requires leaving the access point. That is the whole move.
- the failure is one-sided. The M5Stack runs no Bluetooth and held up fine; the
  dongle carries a controller and went deaf. It only looked symmetric because
  the inviter sends nothing while it waits for the step-4 proof, so the M5Stack
  having nothing to receive was correct behaviour, not a second fault.
- it is not the scan. Cancelling the scan does not give the radio back. The
  controller merely being up is enough.
- `esp_coex_preference_set(ESP_COEX_PREFER_WIFI)` does not change it either.

The only thing measured to restore reception is taking the controller all the
way down (`nimble_port_stop()` then `nimble_port_deinit()`), which recovers it
immediately and completely.

### What this means for section 23.7 on this hardware

A station carrying a BLE controller cannot leave its access point and still
hear anybody. Three honest options, none free:

1. **Stop Bluetooth for the away window** and start it again on return. Measured
   to work. It costs the whole BLE mesh plane for the length of the exchange,
   and re-initialising NimBLE is not instant.
2. **Do not move.** section 23.7 already lets an invitee answer `s:no`, and an
   indexer that is somebody's only uplink is exactly the station that should.
   The rule becomes: a station with Bluetooth running does not accept a channel
   invitation, and the pair uses what they already share.
3. **Never disassociate** -- only ever meet on the access point's own channel,
   which is not a move at all and buys nothing.

Option 2 is the one that costs nothing and is already in the specification.
Option 1 is worth measuring properly before it is offered to anybody.

### The probe

`esp32/espnow_probe`, two environments, same source:

    ~/.platformio/penv/bin/pio run -e tdongle -t upload
    ~/.platformio/penv/bin/pio run -e m5stack -t upload

Console: `ch <n>`, `join`, `leave`, `rate <ms>`, `reset`, `state`,
`ble on|off|kill`, `coex wifi|bt|balance`. Both boards print the same counter
line, so any claim about one of them can be checked against the other. Open each
serial port ONCE and leave it open -- a shell redirect to the M5Stack's CP2104
asserts DTR and reboots the board, which invalidated a whole run before it was
noticed.
