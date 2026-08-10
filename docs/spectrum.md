# XPRS spectrum

Where XPRS packets go on each bearer, and why the answer is not one number.

Status: PROPOSAL. Nothing in this document is blessed by a regulator or by any
other project. Section 11 states what is implemented, which today is none of it.

---

## 1. There is no worldwide band

Unlicensed spectrum is allocated nationally. The 868 MHz band a European station
uses is a licensed mobile band in the United States; the 915 MHz band an American
station uses overlaps GSM-900 uplink in Europe. No frequency is licence-free
everywhere, and no document can make one so.

So this specification does not define *the* XPRS frequency. It defines, per
bearer and per region, the band a station operates in and one **calling
frequency** within it, so that two strangers in the same country who have never
met can find each other without configuration.

What is worldwide is the packet. [XPRS.md](XPRS.md) defines 250 bytes of
`key:value` text that is identical on LoRa in Brazil, on WiFi in Japan and on a
wire between two laptops. A station crossing a border changes its radio settings
and changes nothing else, and a packet relayed across that border arrives
unaltered.

A station announces the channel it is actually using with `t:channel`
([XPRS.md](XPRS.md) section 23), so the tables below are a starting point rather
than a dependency. Two stations that can hear each other at all can agree on
anything else by saying so.

---

## 2. LoRa

The regional bands are those of the LoRa Alliance regional parameters, which
national regulators and every LoRa device already follow. The frequency and
modulation are this document's proposal.

| Region | Band | XPRS frequency | Typical limit |
|---|---|---|---|
| Europe, UK, Africa, Middle East | 863-870 MHz | 869.525 MHz | 500 mW ERP, 10% duty in 869.4-869.65 |
| United States, Canada, Mexico, Brazil | 902-928 MHz | 918.875 MHz | 1 W |
| Australia, New Zealand | 915-928 MHz | 919.900 MHz | 1 W |
| Japan, Singapore, Malaysia, Thailand, Vietnam, Indonesia | 920-925 MHz | 923.400 MHz | 13 dBm, listen-before-talk |
| South Korea | 920-923 MHz | 922.300 MHz | 10 mW, listen-before-talk |
| India | 865-867 MHz | 865.4025 MHz | 30 dBm |
| China | 470-510 MHz | 470.500 MHz | 19 dBm |
| Russia | 864-870 MHz | 869.100 MHz | 25 mW |

**Modulation: SF9, 250 kHz bandwidth, coding rate 4/5.** Everywhere. A network
that does not agree on this cannot hear itself, and it is the setting that makes
the frequency choice work.

### 2.1 Sharing with Meshtastic and MeshCore

Outside Europe the frequencies above are chosen at least a megahertz clear of the
Meshtastic regional defaults, because the band has room and there is no reason
to fight over a channel.

Europe has no room. The only sub-band offering 500 mW and 10% duty is
869.4-869.65 MHz, which is **250 kHz wide -- exactly one LoRa channel**. There is
no second slot to move to. Meshtastic sits there because there is nowhere else,
and so does everything else: regulators in Norway have measured heavy smart-meter
activity across 869.525 MHz and above.

So in Europe XPRS shares the channel deliberately, and separates itself by
modulation instead. Meshtastic's default preset is SF11 at 250 kHz; XPRS is SF9.

Different spreading factors are quasi-orthogonal, so each network rejects much of
the other's signal rather than being deafened by it. **That is a partial defence
and this document does not pretend otherwise**: LoRa exhibits capture, so a
strong interferer wins whatever its spreading factor, and two networks in one
250 kHz channel will cost each other packets.

The stronger argument for SF9 is not orthogonality but airtime:

| | 250 B packet | Silence owed at 10% duty | Airtime vs LongFast |
|---|---|---|---|
| SF9, 250 kHz | 615 ms | 5.5 s | 30% |
| SF11, 250 kHz (Meshtastic) | 2050 ms | 18.5 s | 100% |

XPRS occupies the channel for **less than a third** of the time Meshtastic needs
for the same 250 bytes. Sharing a channel politely means being on it briefly, and
that does more for the neighbours than any choice of spreading factor.

The cost is sensitivity: SF9 is 5 dB below SF11, which is roughly two thirds of
the range in typical suburban propagation. XPRS accepts that, because a 250-byte
packet format designed around relaying and carrying is better served by many
short transmissions than by few long ones.

Every figure in the table above is **computed from the modulation**, and none of
it says what is happening on a real channel on a real evening. `busy:` and
`txtime:` ([XPRS.md](XPRS.md) section 10.6) are the measured version: how much of
the last hour a bearer was occupied by anybody, and how much of it was this
station. Each reading names its bearer in `link:`, so a station on LoRa and a LAN
at once reports each honestly instead of averaging them into nothing.

A duty cycle constrains one transmitter; whether the band is usable depends on
all of them, and that is the number worth having before choosing a spreading
factor for a site rather than for a spreadsheet.

A denser urban network may prefer SF8 -- more orthogonal still, 17% of the
airtime, about half the range. A long rural link may prefer SF11 and accept the
contention. Both are legitimate; the station says which it uses in `t:channel`.

### 2.2 Range over water

**LoRa at sea is not limited by signal strength. It is limited by the horizon.**

At 500 mW and SF9 the budget is 161 dB, which is three thousand kilometres of
free space. At the distances a boat actually works, most of that is unused:

| Path | Horizon | Budget left there |
|---|---|---|
| deck to deck, 2 m | 12 km | 48 dB |
| masthead to masthead, 15 m | 32 km | 40 dB |
| kite to kite, 30 m | 45 km | 37 dB |
| masthead to a coastal station at 100 m | 57 km | 35 dB |
| masthead to a mountain at 500 m | 108 km | 29 dB |

So roughly **30 km boat to boat and 60 km boat to shore**, and the radio is never
the reason. Adding power to a link with 40 dB spare changes nothing. Adding
height changes everything, because what stops the signal is the sea getting in
the way:

| Path | Earth bulge at midpoint | First Fresnel radius |
|---|---|---|
| 20 km | 5.9 m | 1.3 m |
| 30 km | 13.3 m | 1.6 m |
| 50 km | 36.9 m | 2.1 m |
| 80 km | 94.4 m | 2.6 m |

A 15 m masthead barely clears the bulge at 30 km. Reaching 50 km needs about 37 m
at both ends, which is why every long over-water result involves a hill, a cliff
or a lighthouse somewhere in it. This is the one bearer where lifting an antenna
on a kite pays for itself: the margin is already there and only geometry is in
the way.

Two effects belong to water specifically.

**Sea-surface reflection causes deep fades.** The direct and reflected rays
interfere, so signal strength oscillates with distance and with swell: a solid
link, then nothing, then solid again over a few hundred metres of motion. Forty
decibels of margin rides through most of it, but it explains links that work
from one anchorage and not from another two cables away.

**Evaporation ducting is the wildcard.** Over warm water a duct forms in the
first five to forty metres and traps UHF inside it, occasionally giving hundreds
of kilometres far beyond the horizon. Common in the Mediterranean and the
tropics, entirely unschedulable, and it happens at exactly masthead height.

Unlike 27 MHz there is no ionospheric path at 869 MHz, ever. LoRa reaches the
horizon and stops, and everything beyond it is carried (XPRS.md section 13.4)
rather than transmitted.

### 2.3 433 MHz, the other LoRa band

433.05-434.79 MHz is licence-exempt in Europe and cheap LoRa modules for it are
everywhere. It is worth knowing why this document does not propose it as the
default.

| | Power permitted | Budget at SF9 | Free space | Margin at the 32 km sea horizon |
|---|---|---|---|---|
| 868 MHz | 500 mW | 161 dB | 3087 km | 39.7 dB |
| 433 MHz | 10 mW | 144 dB | 874 km | 28.7 dB |

433 MHz propagates better -- 6 dB less path loss than 868 for the same power,
and noticeably better diffraction around buildings and through trees, which is
where sub-gigahertz links are actually lost. But Europe permits 10 mW there
against 500 mW at 868, and 17 dB of power beats 6 dB of physics. The net is
about 11 dB worse.

It still clears the horizon at sea with 29 dB to spare, so a boat using 433 MHz
loses nothing over water. The place it wins is dense obstruction at short range:
a town, a forest, inside a marina. The place it loses is everywhere the extra
power would have mattered.

The band is also crowded with key fobs, weather stations, garage doors and
doorbells, and in the United States 433 MHz is inside the amateur 70 cm
allocation, where Part 15 permits only periodic transmissions rather than a
continuous data link. It is a European option and a secondary one.

**Duty cycle is the binding constraint in Europe, not power.** Ten percent means
a station transmitting for one second is silent for nine, and the table above is
what that costs in practice. A mesh that ignores this is both illegal and
self-defeating: the band is shared with everyone else's meters and alarms.

---

## 3. WiFi HaLow, 802.11ah

Sub-gigahertz WiFi: kilometres rather than tens of metres, at IoT data rates.
The most promising bearer in this document and the least available.

| Region | Band |
|---|---|
| United States | 902-928 MHz |
| Europe | 863-868 MHz |
| Japan | 916.5-927.5 MHz |
| South Korea | 917.5-923.5 MHz |
| Australia, New Zealand | 915-928 MHz |
| China | 755-787 MHz |

1 MHz and 2 MHz channels are the widely supported widths; 4, 8 and 16 MHz exist
where the allocation is wide enough. Europe's 5 MHz of room allows far fewer
channels than the United States' 26 MHz, so a European HaLow network is
narrower and slower by regulation rather than by design.

HaLow shares its band with LoRa in most regions. The two do not interoperate and
will interfere, and a station running both should not run them at once.

### 3.1 Range over water, and why Europe loses it

Same physics as LoRa in section 2.2: sub-gigahertz, no ionospheric path, limited
by the horizon rather than by the radio. What differs is how much budget there is
to spend, and here the regulator decides the answer rather than the engineering.

Taking 1 MHz MCS10, the most sensitive mode, at a receiver sensitivity of
-100 dBm and 2 dBi antennas at both ends:

| | Transmit | Budget | Free-space limit |
|---|---|---|---|
| HaLow, United States | 1 W | 134 dB | 133 km |
| HaLow, Europe | 25 mW | 118 dB | 21 km |
| LoRa SF9, Europe | 500 mW | 161 dB | 2977 km |

Against the horizons from section 2.2:

| Path | Horizon | HaLow US | HaLow EU | LoRa |
|---|---|---|---|---|
| deck to deck, 2 m | 12 km | +21 dB | +5 dB | +48 dB |
| masthead to masthead, 15 m | 32 km | +12 dB | **-4 dB** | +39 dB |
| masthead to coastal 100 m | 57 km | +7 dB | **-9 dB** | +34 dB |
| masthead to mountain 500 m | 108 km | +2 dB | **-14 dB** | +29 dB |

**In the United States HaLow covers the whole over-water horizon**, out to about
100 km, and runs out of budget only past the point where the sea has already
blocked it. It is a genuine maritime bearer there.

**In Europe it does not reach masthead to masthead.** Twenty-one kilometres of
budget against a thirty-two kilometre horizon: the sea is not the limit, the
power limit is. Deck to deck it works with five decibels to spare, which is a
harbour, not a passage.

The reason is worth stating exactly, because it is not fixable by choosing a
better radio. Europe's only generous sub-band is 869.4-869.65 MHz at 500 mW,
which is **250 kHz wide, and HaLow's narrowest channel is 1 MHz**. HaLow
physically cannot fit in the one window that would make it work. It is confined
to the 25 mW parts of 863-868 MHz, and 25 mW is what gives 21 km.

So the same silicon, the same antenna and the same firmware make a usable
maritime link in Florida and a harbour toy in Portugal. This is the clearest
example in this document of the argument in section 10: the only difference
between the two is a number in a table.

Where it does work, HaLow is worth having. A 250-byte packet is 13 ms at MCS10
against 364 ms for LoRa at SF9 -- roughly twenty-seven times the throughput for
comparable range. HaLow is the bearer for moving a file between two boats in an
anchorage; LoRa is the bearer for reaching the one that left yesterday.

Receiver sensitivity varies by vendor, with some parts claiming -105 dBm at this
rate. Those five decibels matter more than they look: they move the European
figure from 21 km to 37 km, which does clear the 32 km masthead horizon, though
with only about 1.4 dB in hand. With the best available receiver Europe gets a
marginal boat-to-boat link and still cannot reach a coastal station at 57 km,
where it remains 4 dB short. The conclusion holds either way; the best case is
"just barely" rather than "not at all".

---

## 4. WiFi, 2.4 GHz

2400-2483.5 MHz is the closest thing to a worldwide unlicensed band, which is why
it is worth using despite being crowded.

| Channel | Centre | Available |
|---|---|---|
| 1 | 2412 MHz | worldwide |
| 6 | 2437 MHz | worldwide |
| 11 | 2462 MHz | worldwide |
| 12, 13 | 2467, 2472 MHz | most of the world, not the United States |
| 14 | 2484 MHz | Japan, 802.11b only |

**Channel 6 is the proposed XPRS calling channel**, being available everywhere
and clear of the 1 and 11 that consumer access points default to.

Section 9 covers using this band connectionlessly.

---

## 5. Bluetooth LE

The only bearer in this document that ships today, and the only one with nothing
to configure.

2400-2483.5 MHz, forty channels of 2 MHz, the same everywhere. Three of them
carry primary advertising:

| Channel | Centre |
|---|---|
| 37 | 2402 MHz |
| 38 | 2426 MHz |
| 39 | 2480 MHz |

**An operator sets no frequency and picks no region.** There is no table to look
up, no duty cycle to budget and no national variant, because the controller does
adaptive frequency hopping and the regulatory work was done by the chipset
vendor. Every other section of this document exists because that is not true
elsewhere.

Range, with the antennas a phone actually has:

| Mode | Budget | Free space |
|---|---|---|
| 1M PHY, 10 dBm | 105 dB | 1.7 km |
| Coded PHY S=8, 10 dBm | 113 dB | 4.4 km |
| Coded PHY S=8, 20 dBm | 123 dB | 13.8 km |

Those are ceilings and a body in the way costs 10 to 20 dB of them. In practice
BLE5 is tens to hundreds of metres between phones and a kilometre or two between
fixed nodes with clear line of sight. At sea it is budget-limited long before the
horizon: 32 km masthead to masthead is well past anything in the table above.

So BLE5 is the bearer for the boat alongside, not the boat over the horizon.
That is exactly the role it plays: [ble5.md](ble5.md) covers the framing, the
advertising rotation and every byte budget on the path, and
[store-and-forward.md](store-and-forward.md) covers what happens when the peer is
not there at all.

---

## 6. Marine VHF, which XPRS does not use

Listed to rule it out, as the United States is ruled out for CB.

156-174 MHz is on every vessel, is internationally harmonised, and would be an
obvious carrier for a maritime packet format. XPRS does not use it, and no
station should be built that does.

**These channels must never carry data under any circumstances:**

| Channel | Frequency | Purpose |
|---|---|---|
| 16 | 156.800 MHz | distress, safety and calling |
| 70 | 156.525 MHz | digital selective calling |
| AIS 1 | 161.975 MHz | AIS position reporting |
| AIS 2 | 162.025 MHz | AIS position reporting |

Channel 70 and the AIS channels are the dangerous ones precisely because they
are already digital, so a transmitter that can generate an XPRS packet can
generate something that lands there. AIS is how ships avoid collisions and
channel 16 is how people are found alive. Interference on either is a
safety-of-life matter and not a spectrum-etiquette one.

Marine VHF also requires a ship station licence and an operator certificate in
most jurisdictions, and permitted emissions are specified per channel. Whatever
room exists for data is not room this project should be exploring.

A station may legitimately *state* that it monitors a marine channel, using
`t:channel` with `kind:emergency` and no `power:` field, which says it listens
and does not transmit. That is a claim about the operator's attention, not a
transmission plan.

---

## 7. Licence-free voice bands

These carry XPRS only as audio-frequency modulation over a voice channel, which
is slow and which this document does not specify. They are listed because a
station's `t:channel` announcements will name them and because operators ask.

**CB, 26.965-27.405 MHz, 40 channels.** The most internationally consistent
allocation on this page: the same 40 channels are licence-free across CEPT
Europe, the United States, and much of South America and Asia, though power and
permitted modes differ. Typically 4 W for AM and FM, 12 W PEP for SSB.

**Channel 24, 27.235 MHz, is the proposed XPRS calling channel, in Europe only.**

That is not an invention. Germany designates channels 24 and 25 as the digital
CB channels, and channel 24 has carried 1200 baud AFSK packet radio for years.
Aligning with an existing convention costs nothing and puts XPRS where operators
already expect to hear data.

Channels to keep clear of: **9 (27.065 MHz) is the emergency channel** almost
everywhere, and **19 (27.185 MHz) is the road channel**. Neither is ever a
candidate.

Beware the channel table. Channels 23, 24 and 25 are out of numeric order --
23 is 27.255 MHz, above both 24 at 27.235 and 25 at 27.245 -- because the
frequencies between were allocated to radio control. Any code that computes a
frequency from a channel number by arithmetic is wrong for exactly these three.

### 7.1 CB is Europe-only for XPRS

In the United States it is unlawful. 47 CFR 95.931 permits a CB station to
transmit "two-way plain language voice communications" and nothing else, and
every authorised emission -- A3E, F3E, J3E, R3E, H3E -- is a voice emission.
There is no digital mode to fall back on, as there is on PMR446. 95.933 also
prohibits communicating with stations in other countries, Canada excepted.

| Jurisdiction | Data on CB |
|---|---|
| Germany | channels 24 and 25 designated digital; packet established |
| Other CEPT countries | varies; check the national interface requirement |
| United States | **not permitted**; voice emissions only, 47 CFR 95.931 |

**27 MHz is not a local band.** The 11 m band propagates by skywave, so a
transmission that is polite locally can be interference on another continent
where nobody agreed to any of this. Treat airtime here as a shared resource well
beyond the horizon, and beacon sparingly.

**PMR446, 446.0-446.2 MHz, 16 channels, 500 mW ERP.** Europe and CEPT only.
Channel 1 is 446.00625 MHz and channels are spaced 12.5 kHz.

The band has two halves with very different populations:

| Channels | Range | Traffic |
|---|---|---|
| 1 to 8 | 446.00625 - 446.09375 MHz | the original 1998 allocation; almost all of it |
| 9 to 16 | 446.10625 - 446.19375 MHz | added by ECC Decision (15)05 in 2015; quiet, and many older handsets cannot reach it |

**Channel 16, 446.19375 MHz, is the proposed XPRS calling channel.**

Deliberately not channel 3. Channel 3 is the 3-3-3 convention -- channel 3, three
minutes, every three hours -- and people *listen* on it for voice. Putting data
bursts on a channel monitored for human calls is antisocial in both directions,
and the whole value of 3-3-3 is that someone is listening. Channel 16 is the top
of the 2015 extension: legal across CEPT for analogue and digital alike, and
inaudible to the legacy eight-channel radios that make up most of the traffic.

### 7.2 Whether data is permitted on PMR446 at all

Unresolved, and stated as such rather than assumed.

The ECC decisions describe PMR446 as carrying voice, tones, and limited data
through digital modes such as DMR Tier 1 and dPMR Tier 1. They do not plainly
address arbitrary packet data sent as audio through an analogue channel, which
is how APRS works on amateur bands and how XPRS would most cheaply work here.

| Path | Standing |
|---|---|
| data inside DMR Tier 1 or dPMR Tier 1 | clearly contemplated |
| AFSK packet data through an analogue voice channel | not clearly addressed |

National administrations may differ, and an operator is responsible for their
own. **Do not read this document as permission.** Until somebody establishes the
answer for a given country, the digital-mode path is the defensible one.

Two further constraints bind harder than the frequency:

- **No external antenna is permitted.** Unlike LoRa there is no legal way to
  improve the link; what the handset gives is what there is. Roughly 1 to 3 km
  in a town, 5 to 8 km over open ground, considerably more hilltop to hilltop.
- **A 250-byte packet is about two seconds of airtime** at 1200 baud AFSK, or
  under a second at 9600. That is APRS's own model and it works, but it is slow
  enough that the channel must be shared politely rather than beaconed into.

PMR446 has no worldwide equivalent, and this is the clearest example of the
problem this document opens with:

| Region | Service | Band |
|---|---|---|
| Europe, CEPT | PMR446 | 446.0-446.2 MHz |
| United States | FRS | 462.5625-467.7125 MHz |
| United States | MURS | 151.820-154.600 MHz |
| Japan | Specified Low Power | 421-422 MHz |
| Australia | UHF CB | 476.425-477.4125 MHz |

None of those has an agreed XPRS channel. Proposing one for a service this
document's authors cannot test would be guessing, and a wrong guess here puts
somebody on a channel their regulator reserved for something else.

A radio legal in Lisbon is illegal in Chicago and vice versa. Nothing in
software fixes that.

---

## 8. Licensed bands: HF, VHF and UHF

### 8.1 VHF and UHF

An `X1` or `X3` callsign is self-generated and must never be originated onto
licensed spectrum ([XPRS.md](XPRS.md) section 9.4.1): only a callsign issued by
a competent authority to the operator transmitting may be used here. Everything
in this section applies to such an operator, who binds that callsign to their
signing key with `t:identity` (section 9.4.2) and may not encrypt (section 9.4).

| Band | Region 1 | Region 2 | Region 3 |
|---|---|---|---|
| 2 m | 144-146 MHz | 144-148 MHz | 144-148 MHz |
| 70 cm | 430-440 MHz | 420-450 MHz | 430-440 MHz |

**Use the regional APRS frequency. Do not allocate a new one.**

| Region | Frequency |
|---|---|
| Europe and most of Region 1 | 144.800 MHz |
| North America | 144.390 MHz |
| Australia | 145.175 MHz |
| Japan | 144.640 MHz |

XPRS on VHF is an AX.25 UI frame at 1200 baud AFSK, which is what APRS has been
for thirty years. That is the whole argument: **an existing TNC, an existing
radio and an existing digipeater network carry XPRS unmodified**, because at the
link layer there is nothing to change. A station needs new software and no new
hardware.

Allocating a separate XPRS frequency would throw that away, split a working
network, and leave both halves worse.

Two things follow from sharing a channel with APRS.

An XPRS packet must be distinguishable from an APRS one, so that APRS software
ignores it rather than misparsing it. The AX.25 destination address is the field
that does this, and **XPRS should register its own** with the tocall registry
before anybody transmits. This document does not assign one, because inventing
an unregistered destination address is how two projects end up colliding in a
namespace built to prevent exactly that.

And the channel is shared with a live network that was there first. 144.800 MHz
in Europe carries real traffic; XPRS beaconing at APRS rates would degrade a
service other people depend on. Same etiquette, same duty, and no assumption
that the band is empty because your own software cannot hear anything on it.

### 8.2 HF, the only bearer that crosses an ocean

Everything else in this document stops at the horizon. HF does not, because
3 to 30 MHz refracts off the ionosphere instead of running into the sea.

| Service | Bands | Licence |
|---|---|---|
| Marine SSB | ITU maritime allocations, 2-26 MHz | ship station licence and operator certificate |
| Amateur HF | 3.5, 7, 14, 18, 21, 24, 28 MHz | amateur licence |

There is no licence-exempt HF. Both routes require paperwork, and the amateur
route additionally forbids encryption (section 9.4 of [XPRS.md](XPRS.md)) and
requires the operator's own callsign, never a self-generated `X1` or `X3` one.

Which band depends on the hour and the distance. 14 MHz carries 2000 km and more
in daylight; 7 MHz does the same after dark; 3.5 MHz fills the gap underneath at
a few hundred kilometres by near-vertical incidence. A station wanting one
frequency all day will not find one.

Data on HF is established rather than experimental: VARA HF, JS8Call, Winlink and
FT8 all move traffic over thousands of kilometres at a few hundred bits per
second, and Winlink in particular exists to carry email to vessels at sea. An
XPRS packet is 250 bytes, which is a comfortable payload for any of them.

On a boat the antenna is usually already there. An insulated backstay is the
standard marine HF radiator, and a hull in salt water is the best RF ground
available, which is why HF from a vessel outperforms the same rig ashore.

The honest position: HF is the only bearer here that reaches 2000 km on demand,
and it is out of reach for an unlicensed station. For everyone else that distance
is covered by carrying the packet (section 13.4 of [XPRS.md](XPRS.md)) rather
than transmitting it, which trades days of latency for needing no licence, no
antenna and no ionosphere.

---

## 9. WiFi without association

### 9.1 What monitor mode does and does not buy

**Monitor mode does not increase range.** Range on a WiFi bearer comes from data
rate, band and power: 802.11b at 1 Mbps is roughly 10 to 20 dB more sensitive
than OFDM at 54 Mbps, which is worth two or three times the distance, and 802.11ah
at 900 MHz is worth an order of magnitude more than either. None of that requires
monitor mode and all of it is available while associated.

What monitor mode buys is **connectionless operation**, and that is the part
worth having. Ordinary WiFi requires association: a station picks an access
point, authenticates, gets an address, and can then talk to whatever is behind
it. Every step is a negotiation, every negotiation is a failure mode, and the
result reaches exactly the peers that joined the same network.

A radio does none of that. It transmits and whoever is listening hears it. That
is what BLE5 extended advertising already gives this project
([ble5.md](ble5.md)) and what makes it the off-grid plane. WiFi in monitor mode
is the same idea with 20 MHz of bandwidth instead of 2 MHz, and it is the right
shape for XPRS: a packet is 250 bytes addressed to a callsign, not a session.

So the honest framing is that this is a **bandwidth and topology** improvement
over BLE5, not a range improvement over anything.

### 9.2 The obstacle

Most Android phones cannot do it. The Broadcom and Qualcomm chipsets in mainstream
handsets ship without monitor mode or frame injection; enabling either needs a
rooted device and, on recent Qualcomm parts, driver patches that override service
capabilities and bypass firmware filters. Work continues on several chipsets, but
none of it is something an application can rely on.

Aurora is primarily an Android application. A bearer that requires root is not a
bearer, it is a laboratory.

### 9.3 The plan

Four steps, in order of what is possible today.

**Step 1: WiFi Aware where the platform offers it.** Android exposes Neighbour
Awareness Networking: publish and subscribe without association, without an
access point, and without root. It is connectionless in exactly the sense above,
it is supported on a large fraction of devices from Android 8 onward, and it
needs no permission the application does not already hold. This is the step that
delivers the architecture the user asked for on stock hardware.

**Step 2: keep WiFi Direct as the bulk lane.** Already implemented
(`lib/services/wifi_direct/wifi_direct_coordinator.dart`). It is a session, not a
broadcast, so it is wrong for beacons and right for moving a file once two
stations have found each other by another means. Do not replace it.

**Step 3: monitor mode on the platforms that allow it.** Linux desktops with an
mt76 or similar adapter, and the ESP32, which can transmit and receive raw
802.11 frames without any of this difficulty and is already part of this project.
A fixed vendor-specific element carrying an XPRS packet in a broadcast frame is
straightforward on both. This makes desktops and dongles into the wide-band
equivalent of the BLE5 plane and leaves phones on Aware.

**Step 4: HaLow when hardware appears.** 802.11ah does properly what monitor
mode is being asked to do badly: kilometres, sub-gigahertz, connectionless by
configuration rather than by subversion. The bearer abstraction should be written
so that adding it later is a driver, not a redesign.

### 9.4 What not to do

Do not transmit raw frames from a phone by patching its driver and ship that.
Beyond needing root, altering the radio behaviour of a type-approved device is
the operator's legal exposure, not the application's, and taking that decision on
their behalf inside an app store build is not defensible.

---

## 10. On harmonisation

Aligning national allocations is a decade of committee work and a specification
does not move it. What a specification can do is remove every excuse that is not
regulatory.

If XPRS runs on LoRa, HaLow, WiFi, Bluetooth and the internet with one packet
format, then the only remaining difference between two countries is the number
in the table, and that difference becomes visible and arguable. An operator can
say precisely what they cannot do and why, and point at a working network next
door that does it legally.

That is worth stating plainly and not overstating: the value here is a working
demonstration and an unambiguous specification, and the rest is other people's
work.

---

## 11. Implementation status

| Element | State |
|---|---|
| Bluetooth LE | **implemented**; the off-grid plane today, see [ble5.md](ble5.md) |
| Marine VHF | deliberately not implemented and must not be |
| 433 MHz LoRa | not implemented; documented as a secondary European option |
| HF | not implemented; no HF hardware in this project |
| PMR446 channel 16, CB channel 24 | not implemented; no bearer carries XPRS over an audio channel |
| Regional LoRa plans | not implemented; `lib/connections/lora/lora_connection.dart` sets no frequency, and the SX1262 and SX1276 drivers accept one from a caller that does not yet exist |
| Calling frequencies | not implemented; proposed here for the first time |
| `t:channel` announcements | not implemented ([XPRS.md](XPRS.md) section 23) |
| WiFi Aware | not implemented |
| WiFi Direct | implemented, as a session bearer |
| Monitor mode on desktop or ESP32 | not implemented |
| HaLow | no hardware in this project |
| Region selection in the UI | not implemented; there is no setting to pick one |

The first useful step is the smallest: a region setting and a LoRa frequency
derived from it. Everything else in this document is inert until a station can
be told where in the world it is.
