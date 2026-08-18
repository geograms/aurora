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

## Open: the pair goes deaf on the working channel

Not solved, and recorded here so the next attempt starts from the measurement
rather than from the beginning.

After both stations move to channel 6, **each reports itself on channel 6, each
driver reports its frames sent, and neither receives a single byte from the
other** -- deaf in both directions at once, for the whole 15-second window. The
same exchange aimed at channel 1 (the access point's own channel, so no real
retune happens) meets 2 times in 3. So the retune is the dominant fault and
something smaller is intermittent even without it.

Ruled out by measurement, so do not re-test these first:

- **not the acceptance being lost** -- it arrives on the commons every time, and
  the inviter moves on it
- **not the disassociation being slow** -- `let go of the access point in 0ms`,
  and the channel is read back from the driver after setting it (`radio says 6`)
- **not heap or a refused send** -- `sent=n/n fail=0` throughout
- **not power save or the peer's channel** -- `esp_wifi_set_ps(WIFI_PS_NONE)` and
  an explicit `esp_now_mod_peer` channel are both re-asserted after every move,
  and neither changed the result

- **not an off-channel scan** -- `esp_wifi_scan_stop()` is called on the way out
  and returned "no scan to stop" every single time, and the drift guard that
  re-reads the channel on every tick while away has never once reported the
  radio somewhere else. The station is genuinely parked on the working channel
  for the whole window and still hears nothing.
- **not channel 6 in particular** -- the same run aimed at channel 11 met 1 time
  in 5, which is channel 6's rate. It is not local interference on one channel.

One thing IS known to break the return leg, and is in the code as a warning:
`esp_wifi_scan_stop()` must not be called on the way home. `esp_wifi_connect()`
starts a scan, and stopping it strands the station on the working channel --
measured as "back on the calling channel" while the heartbeat still said `ch=6`.

What has not been tried: a pair of boards doing this with NOTHING else running
(no iGate, no hub, no BLE, no SD), to establish whether two ESP-NOW stations can
hold a manually-set channel at all on this silicon, or whether the coexistence
scheduler on a board carrying Bluetooth is the thing that never yields receive
time once the station is not associated. That is the experiment this needs next,
and it wants a stripped firmware rather than another change to this one.
