# XPRS on the local network

A station attached to a WiFi or an ethernet has a bearer that costs nothing and
carries everything: the wire itself. This is that bearer -- XPRS packets
broadcast to everyone on the network, and heard from everyone on it.

[ble5.md](ble5.md) is the Bluetooth bearer's page; this is the LAN's.
[XPRS.md](XPRS.md) already assigns it: `link:lan` is a bearer (section 10.6) and
`scope:local` explicitly permits "the network it is attached to"
(section 13.11.1).

## What this is not

**Not Reticulum, and not the internet.** No links, no identities, no routing, no
gateway, nothing that leaves the wire it is attached to. A packet on this bearer
reaches the machines in the building and stops there.

Aurora's Reticulum LAN discovery uses UDP 42671 and is a different protocol on a
different socket. The ESP32 firmware listens to it separately
(`geogram_lanwatch`) and nothing here changes that.

Three sockets travel this wire, and it is worth being able to name them:

| | |
|---|---|
| **UDP 4242** | this bearer — XPRS broadcast, everyone hears everyone |
| **TCP 4242** | XPRS and Reticulum on one connection, told apart by the first byte ([XPRS.md](XPRS.md) section 24.4) |
| **UDP 42671** | Reticulum's LAN discovery. Not XPRS, and not touched here |

## The wire

```
UDP, broadcast to 255.255.255.255, port 4242
one XPRS packet per datagram, verbatim, no header
```

The port is the one XPRS already answers on over TCP (section 24.4). Broadcast
needs it on UDP because TCP needs an address and the first station on a network
knows nobody's; the two sockets never collide, so it is one number rather than
two.

There is nothing else to it. The packet is what was composed and signed
(section 4), it arrives byte for byte, and a receiver decides what it is by
parsing it: a datagram that is not a well-formed XPRS packet is dropped.

That is deliberate. There is no version to negotiate, no envelope to strip and
no framing to get wrong, so a new station joins the bearer by opening a socket.
A packet is at most 250 bytes, so it always fits one datagram and is never
fragmented.

## Not everybody at once

Every station on a broadcast network hears the same packet at the same moment,
and each one willing to relay it would transmit immediately. Section 13.2.1 says
what to do instead, and this bearer implements it:

| | |
|---|---|
| A packet from another bearer | waits **200--1200 ms**, chosen at random |
| The same packet heard meanwhile | the waiting copy is **dropped** |
| A packet this station composed | goes out **immediately**, with no `via:` |

The cancel is what makes it work: with three dongles on one LAN hearing the same
Bluetooth packet, one airs it and the other two throw theirs away. The
identifier they compare is the section 5 one, which ignores `via:` and `sig:`,
so a relayed copy is recognisably the same packet.

A station also remembers what it has already put on the LAN, so it never airs
the same packet twice.

## What crosses to Bluetooth

Both ways, under the ordinary relay rules -- this is a station with two bearers,
not a special case:

- **Bluetooth to LAN.** Every XPRS packet heard on the air is offered to the
  LAN, which appends this station to `via:` and applies the section 13.1 budget
  (`sos` and `warning` 9 hops, everything else 3). A packet that names this
  station in `via:` already is not relayed (section 13.2).
- **LAN to Bluetooth.** The same, in reverse, through the broadcast-parcel
  chunker any Aurora scanner already reassembles.

`scope:local` packets **do** cross, because both are short-range bearers
(section 13.11.1). They still never reach APRS-IS or the internet: that gateway
is a separate path and is not fed from here.

The asymmetry worth knowing: a LAN carries more in a second than the radio
carries in a minute, so the Bluetooth direction is the one that needs a limit,
not the LAN one.

## Its own beacon

Every five minutes a station says it is there, in the shape section 10.6 already
defines for describing a bearer:

```
t:observation f:X3WWAJ link:lan peers:3
```

`peers:` is how many distinct stations it has heard on the LAN. Nothing has to
be discovered for the bearer to work -- a broadcast reaches everyone regardless
-- but a station that never speaks is indistinguishable from one that is not
there.

## On the T-Dongle

`geogram_xprslan` is the implementation, and everything heard on the LAN goes
into the same index as everything heard on the radio (`geogram_xprsindex`), so
`GET /api/xprs` answers about both. The bearer starts by default once WiFi is
initialised, including when the dongle is serving only its own SoftAP -- the
stations joined to it are a local network too.

**One caveat measured on the hardware:** with BLE and WiFi both active, this
board's WiFi association degrades within minutes (`wifi:m f null` in the log,
then no route). That is a coexistence problem in the firmware's radio sharing,
not in this bearer -- it happens with the LAN bearer removed as well -- but it
does mean the two bearers are not yet reliably up at the same time on a
T-Dongle-S3.
