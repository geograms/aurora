# OPRS spectrum

Where OPRS packets go on each bearer, and why the answer is not one number.

Status: PROPOSAL. Nothing in this document is blessed by a regulator or by any
other project. Section 9 states what is implemented, which today is none of it.

---

## 1. There is no worldwide band

Unlicensed spectrum is allocated nationally. The 868 MHz band a European station
uses is a licensed mobile band in the United States; the 915 MHz band an American
station uses overlaps GSM-900 uplink in Europe. No frequency is licence-free
everywhere, and no document can make one so.

So this specification does not define *the* OPRS frequency. It defines, per
bearer and per region, the band a station operates in and one **calling
frequency** within it, so that two strangers in the same country who have never
met can find each other without configuration.

What is worldwide is the packet. [OPRS.md](OPRS.md) defines 250 bytes of
`key:value` text that is identical on LoRa in Brazil, on WiFi in Japan and on a
wire between two laptops. A station crossing a border changes its radio settings
and changes nothing else, and a packet relayed across that border arrives
unaltered.

A station announces the channel it is actually using with `t:channel`
([OPRS.md](OPRS.md) section 23), so the tables below are a starting point rather
than a dependency. Two stations that can hear each other at all can agree on
anything else by saying so.

---

## 2. LoRa

The regional bands are those of the LoRa Alliance regional parameters, which
national regulators and every LoRa device already follow. The calling frequency
is this document's proposal.

| Region | Band | Calling frequency | Typical limit |
|---|---|---|---|
| Europe, UK, Africa, Middle East | 863-870 MHz | 869.525 MHz | 500 mW ERP, 10% duty in 869.4-869.65 |
| United States, Canada, Mexico, Brazil | 902-928 MHz | 906.875 MHz | 1 W, frequency hopping or wideband |
| Australia, New Zealand | 915-928 MHz | 917.0 MHz | 1 W |
| Japan, Singapore, Malaysia, Thailand, Vietnam, Indonesia | 920-925 MHz | 923.2 MHz | 13 dBm, listen-before-talk |
| South Korea | 920-923 MHz | 922.1 MHz | 10 mW, listen-before-talk |
| India | 865-867 MHz | 865.0625 MHz | 30 dBm |
| China | 470-510 MHz | 470.3 MHz | 19 dBm |
| Russia | 864-870 MHz | 868.9 MHz | 25 mW |

**Duty cycle is the binding constraint in Europe, not power.** Ten percent in the
high-power sub-band means a station transmitting for one second is silent for
nine, and a mesh that ignores this is both illegal and self-defeating: the band
is shared with everyone else's meters and alarms.

Modulation is not fixed here. Spreading factor, bandwidth and coding rate trade
range against airtime, and a network chooses them together or its members cannot
hear each other. A station states what it uses in `t:channel`.

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

**Channel 6 is the proposed OPRS calling channel**, being available everywhere
and clear of the 1 and 11 that consumer access points default to.

Section 7 covers using this band connectionlessly.

---

## 5. Licence-free voice bands

These carry OPRS only as audio-frequency modulation over a voice channel, which
is slow and which this document does not specify. They are listed because a
station's `t:channel` announcements will name them and because operators ask.

**CB, 26.965-27.405 MHz, 40 channels.** The most internationally consistent
allocation on this page: the same 40 channels are licence-free across CEPT
Europe, the United States, and much of South America and Asia, though power and
permitted modes differ. Channel 9 is the emergency channel almost everywhere and
must not be used for data.

**PMR446, 446.0-446.2 MHz, 16 channels, 500 mW ERP.** Europe and CEPT only.
Channel 1 is 446.00625 MHz and channels are spaced 12.5 kHz.

The band has two halves with very different populations:

| Channels | Range | Traffic |
|---|---|---|
| 1 to 8 | 446.00625 - 446.09375 MHz | the original 1998 allocation; almost all of it |
| 9 to 16 | 446.10625 - 446.19375 MHz | added by ECC Decision (15)05 in 2015; quiet, and many older handsets cannot reach it |

**Channel 16, 446.19375 MHz, is the proposed OPRS calling channel.**

Deliberately not channel 3. Channel 3 is the 3-3-3 convention -- channel 3, three
minutes, every three hours -- and people *listen* on it for voice. Putting data
bursts on a channel monitored for human calls is antisocial in both directions,
and the whole value of 3-3-3 is that someone is listening. Channel 16 is the top
of the 2015 extension: legal across CEPT for analogue and digital alike, and
inaudible to the legacy eight-channel radios that make up most of the traffic.

### 5.1 Whether data is permitted here at all

Unresolved, and stated as such rather than assumed.

The ECC decisions describe PMR446 as carrying voice, tones, and limited data
through digital modes such as DMR Tier 1 and dPMR Tier 1. They do not plainly
address arbitrary packet data sent as audio through an analogue channel, which
is how APRS works on amateur bands and how OPRS would most cheaply work here.

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

None of those has an agreed OPRS channel. Proposing one for a service this
document's authors cannot test would be guessing, and a wrong guess here puts
somebody on a channel their regulator reserved for something else.

A radio legal in Lisbon is illegal in Chicago and vice versa. Nothing in
software fixes that.

---

## 6. Amateur bands, licensed operators only

An `X1` or `X3` callsign is self-generated and must never be originated onto
amateur spectrum ([OPRS.md](OPRS.md) section 25). Everything here applies to a
licensed operator using their own callsign, and encryption is not permitted
(section 9.4 of that document).

| Band | Region 1 | Region 2 | Region 3 |
|---|---|---|---|
| 2 m | 144-146 MHz | 144-148 MHz | 144-148 MHz |
| 70 cm | 430-440 MHz | 420-450 MHz | 430-440 MHz |

For data, use the regional APRS frequency rather than a new one: 144.800 MHz in
Europe and most of Region 1, 144.390 MHz in North America, 145.175 MHz in
Australia, 144.640 MHz in Japan. OPRS is APRS-shaped and shares its channel
etiquette; adding a second frequency would split a working network to no
purpose.

---

## 7. WiFi without association

### 7.1 What monitor mode does and does not buy

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
shape for OPRS: a packet is 250 bytes addressed to a callsign, not a session.

So the honest framing is that this is a **bandwidth and topology** improvement
over BLE5, not a range improvement over anything.

### 7.2 The obstacle

Most Android phones cannot do it. The Broadcom and Qualcomm chipsets in mainstream
handsets ship without monitor mode or frame injection; enabling either needs a
rooted device and, on recent Qualcomm parts, driver patches that override service
capabilities and bypass firmware filters. Work continues on several chipsets, but
none of it is something an application can rely on.

Aurora is primarily an Android application. A bearer that requires root is not a
bearer, it is a laboratory.

### 7.3 The plan

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
A fixed vendor-specific element carrying an OPRS packet in a broadcast frame is
straightforward on both. This makes desktops and dongles into the wide-band
equivalent of the BLE5 plane and leaves phones on Aware.

**Step 4: HaLow when hardware appears.** 802.11ah does properly what monitor
mode is being asked to do badly: kilometres, sub-gigahertz, connectionless by
configuration rather than by subversion. The bearer abstraction should be written
so that adding it later is a driver, not a redesign.

### 7.4 What not to do

Do not transmit raw frames from a phone by patching its driver and ship that.
Beyond needing root, altering the radio behaviour of a type-approved device is
the operator's legal exposure, not the application's, and taking that decision on
their behalf inside an app store build is not defensible.

---

## 8. On harmonisation

Aligning national allocations is a decade of committee work and a specification
does not move it. What a specification can do is remove every excuse that is not
regulatory.

If OPRS runs on LoRa, HaLow, WiFi, Bluetooth and the internet with one packet
format, then the only remaining difference between two countries is the number
in the table, and that difference becomes visible and arguable. An operator can
say precisely what they cannot do and why, and point at a working network next
door that does it legally.

That is worth stating plainly and not overstating: the value here is a working
demonstration and an unambiguous specification, and the rest is other people's
work.

---

## 9. Implementation status

| Element | State |
|---|---|
| PMR446 channel 16 as the calling channel | not implemented; no bearer carries OPRS over an audio channel |
| Regional LoRa plans | not implemented; `lib/connections/lora/lora_connection.dart` sets no frequency, and the SX1262 and SX1276 drivers accept one from a caller that does not yet exist |
| Calling frequencies | not implemented; proposed here for the first time |
| `t:channel` announcements | not implemented ([OPRS.md](OPRS.md) section 28) |
| WiFi Aware | not implemented |
| WiFi Direct | implemented, as a session bearer |
| Monitor mode on desktop or ESP32 | not implemented |
| HaLow | no hardware in this project |
| Region selection in the UI | not implemented; there is no setting to pick one |

The first useful step is the smallest: a region setting and a LoRa frequency
derived from it. Everything else in this document is inert until a station can
be told where in the world it is.
