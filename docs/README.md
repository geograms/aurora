# Aurora protocol & networking docs

Aurora is an off‑grid‑first messenger. It speaks several protocols at once and
glues them together so a message — or a file — reaches the other side over
whatever path is available: the internet, a Reticulum overlay, an APRS network,
or a direct Bluetooth link.

These documents describe **how Aurora actually implements** each layer (with
file/line pointers into the code), not an idealised spec.

| Doc | What it covers |
|-----|----------------|
| [reticulum.md](../../reticulum-dart/doc/reticulum.md) | The pure‑Dart Reticulum (RNS) stack: packets, announces, hop‑by‑hop routing, identity/crypto, links, resource transfer, and the interfaces (TCP/UDP/BLE/Auto). |
| [dht.md](../../reticulum-dart/doc/dht.md) | The Kademlia‑style DHT that runs over Reticulum: node IDs, k‑buckets, the RPC protocol, signed provider records, publish/resolve, and how files are **found by hash**. |
| [file-sharing.md](../../reticulum-dart/doc/file-sharing.md) | Content‑addressed file hosting: how a file is referenced in chat, the decentralized resolution tiers, **find‑by‑hash vs find‑by‑text**, and how **every downloader becomes a seeder**. |
| [XPRS.md](XPRS.md) | **eXtended Packet Radio System**: the complete protocol specification, an APRS replacement needing no licence. One syntax (`key:value` fields separated by spaces), callsigns of any length, and 27 packet types covering messages, blog posts, observations, tracks, passages, events, offers and needs, radio channels, mailboxes, station services, bot commands and their results, calls for help, warnings, notices and callsign challenges. `t:status` is the townhall packet a social network is made of — a short post about the sender now, optionally carrying one of thirty `mood:` words drawn from general, sea and mountain life so a client can theme itself to how the sender feels. Identifiers are derived from the packet rather than transmitted, so a message arriving by two routes is recognised once. Packets are signed by default, and only a callsign issued by a competent authority may be transmitted on licensed spectrum, which an operator binds to their signing key so amateur traffic stays in clear text and still proves who wrote it; a message can be carried toward a place by whoever is going that way and answered with a signed receipt naming the route; a station publishes as many mailboxes as it needs, each bounded by `since:` and `until:`, so where to reach somebody in November is answerable in August; `scope:` keeps community traffic off the internet; `lang:` names the language and `nick:` the operator. A group that needs a member list holds its own keypair and is addressed by the `X5` callsign derived from it, so a fake admin cannot exist and succession is handing the key over rather than any protocol ceremony; subgroups nest five levels deep and are themselves ordinary groups, so listing one names it without gaining any authority inside it — while a client filters display only, never reception, and never filters a call for help. Coming back after four days at sea, `cmd:history` asks a station to re-air what it kept — the replay is the original signed packets, and derived identifiers collapse the duplicates, so backfill needs no cursors and no trust in whoever held them; `cmd:file` fetches the bytes behind a `file:` hash. `t:place` reports something that is not you and does not move — an anchorage, a spring, a bothy, a trailhead. Every measurement carries its unit, prices their currency, and `cw:` warns what a packet contains before it renders. Section 29 states what a station owes a stranger who asks it to spend airtime. Section 33 is a printable cheat sheet and section 34 states what the shipping code does not yet do. |
| [spectrum.md](spectrum.md) | **Where XPRS packets go on each bearer**, and why the answer is not one number: the regional LoRa bands with a proposed calling frequency for each, HaLow and 2.4 GHz WiFi allocations, CB and PMR446 and their incompatible cousins, the amateur bands a licensed operator may bridge on, and a four-step plan for connectionless WiFi that starts with WiFi Aware because monitor mode needs root on almost every phone. Status: proposal, none of it implemented. |
| [QO-100.md](QO-100.md) | **Two ways to reach a satellite.** QO-100 on Es'hail-2 is geostationary, free of charge, covers a third of the planet and needs an amateur licence; its narrowband transponder carries data and its wideband one moves 10 MB in under three minutes over DVB-S2. Direct-to-LEO LoRa needs no licence at all -- 25 mW reaches orbit with margin, and ECC Report 357 covers it -- but is slow and only in passes. Hardware that works and hardware that does not, why jamming has no defence, and why the second option suits this project better. Research, none of it implemented. |
| [aprs.md](aprs.md) | The APRS transport: APRS‑IS (TNC2) framing, the wapp's connection/iGate behaviour, and how Aurora gates traffic between Bluetooth and APRS‑IS. |
| [fdroid.md](fdroid.md) | Every network host the **built APK** can reach, audited from the binary rather than the source: what was removed (Esri tiles, the GitHub URL rewriter), what is gated (`--dart-define=SELF_UPDATE=false`), what remains and why, and the one open blocker (the proprietary ML Kit blob behind QR scanning). |
| [architecture.md](architecture.md) | **Start here before changing anything.** What belongs in the core and what belongs in a wapp, which isolate may run what, and the guard (`tool/arch_guard.dart`) that enforces both. |
| [ble5.md](ble5.md) | How bytes actually leave the device: the single advertising set and its rotation, frame subtypes, the size router and every byte budget on the path, the receive choke point, and the traps (aired-once is a lottery, `scf=24` means full, asymmetric links). |
| [store-and-forward.md](store-and-forward.md) | Delivering to someone who is not there: why every up-front reachability test lies, the courier's wire format, who carries a stranger's mail and under what quota, the two delivery paths, the counters, and how to validate it without fooling yourself. |
| [ble.md](ble.md) | The Bluetooth transport: the size‑routed split between connectionless APRS broadcast and GATT Reticulum links, the compact frame format, the digipeater, and the store‑and‑forward iGate. |
| [aprs-xt.md](aprs-xt.md) | APRS-XT — the message‑level conventions layered on plain APRS (groups, threads, reactions, signed/encrypted messages, public‑key beacons, embedded media references). |
| [mesh.md](mesh.md) | The BLE street mesh: gossip route beacons, distance‑vector routing, GATT custody transfer, store‑and‑forward, politeness backoff. |
| [chat-rooms.md](chat-rooms.md) | Chat rooms as NIP‑72 communities + a signed moderation op‑log: subtree‑scoped admin/mod authority, kick/suspend/ban/points, and a client‑side 1‑10 reputation. Federates to any standard NOSTR relay. |
| [folders.md](folders.md) | Mutable shared folders over Reticulum: key‑addressed directories backed by a signed, append‑only op‑log. |
| [sync.md](sync.md) | Collab (multi‑writer) folders and cross‑device sync built on top of mutable folders. |
| [NOSTR.md](NOSTR.md) | **The vision**: every user a relay, self‑nominated indexers that answer *where* (not *what*), and one account living on the internet and on Reticulum at once. Marks what is built and what is not. |
| [nostr-client.md](nostr-client.md) | The NOSTR client wapp and its transport‑abstract relay hub (wss + Reticulum + local store). |
| [social.md](social.md) | The **Social wapp** in practice: how the curated All feed works (main‑isolate poll‑and‑close, reaction‑driven curation, profiles, likes, the "(updated)" label), and the lessons/traps for anyone changing it — chiefly that the engine isolate freezes on socket reopen. |
| [esp32.md](esp32.md) | The ESP32 dongle firmware map: project layout, which firmware is which, BLE protocol state, and the traps. |
| [performance.md](performance.md) | Where CPU and memory actually go: the isolate layout, the built‑in `perf:` telemetry, the bugs we fixed (and how each was found), how to measure without fooling yourself, and what is deliberately **not** worth optimising. |

## The big picture

```
            ┌─────────────────────────────────────────────────────────┐
            │                     Aurora chat (wapps)                  │
            │   APRS-XT message conventions  +  file: media references    │
            └───────────────┬───────────────────────┬─────────────────┘
                            │                       │
                 message transport          file transport / discovery
                 ┌──────────┴──────────┐    ┌────────┴───────────────┐
                 │  APRS‑IS    BLE      │    │  Reticulum links        │
                 │  (TNC2)   (compact)  │    │  + DHT (find by hash)   │
                 │                      │    │  + relay (find by text) │
                 └──────────────────────┘    └────────┬───────────────┘
                                                      │
                                              ┌───────┴────────┐
                                              │  Reticulum RNS  │
                                              │  TCP/UDP/BLE/Auto│
                                              └─────────────────┘
```

- **Messages** ride APRS (internet APRS‑IS or off‑grid BLE). The wire format and
  conventions are documented in [aprs.md](aprs.md) / [ble.md](ble.md) /
  [aprs-xt.md](aprs-xt.md).
- **Files** are *referenced* inside those messages by their content hash
  (`file:<sha256>.<ext>`) and *transferred* out of band over Reticulum, the DHT,
  a LAN, I2P, or BitTorrent — see [file-sharing.md](../../reticulum-dart/doc/file-sharing.md).
- **Reticulum** ([reticulum.md](../../reticulum-dart/doc/reticulum.md)) is the transport that lets two
  devices on different networks reach each other at all; the **DHT**
  ([dht.md](../../reticulum-dart/doc/dht.md)) is the decentralized index that lets them find *who holds a
  file* without any central server.

## Identity & keys

Each station has a **Nostr keypair** (secp256k1). Every node **periodically
announces its public key on APRS‑IS** (and BLE) — a bulletin to the reserved
group `NOSTR`, **hourly, on by default**. Peers collect these into a
`callsign → public‑key` map, which is what lets them **verify signed messages**
and **encrypt 1:1 messages** to a callsign. The same key material is the
`npub`/`nsec` shown in the profile and the basis for the social relay's signed
events. Full wire detail in [aprs-xt.md](aprs-xt.md) §10 (announcement), §14 (signing),
§15 (encryption).

## Decentralization, in one paragraph

Finding a file is **content discovery**, and it never goes through a central
index: a holder publishes a signed "I have `<sha256>`" record into the Kademlia
DHT, and a downloader resolves the k‑closest DHT nodes to that hash to learn the
provider set. The only shared infrastructure is a Reticulum **hub** that
*relays transport packets* so two NATed phones can reach each other — it routes
bytes, it never sees or indexes content. And because every device **re‑seeds**
(publishes its own provider record) the moment it finishes a download, the set
of holders grows with each transfer. See [file-sharing.md](../../reticulum-dart/doc/file-sharing.md) for
the verification of both properties against the code.
