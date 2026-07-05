# Aurora protocol & networking docs

Aurora is an off‑grid‑first messenger. It speaks several protocols at once and
glues them together so a message — or a file — reaches the other side over
whatever path is available: the internet, a Reticulum overlay, an APRS network,
or a direct Bluetooth link.

These documents describe **how Aurora actually implements** each layer (with
file/line pointers into the code), not an idealised spec.

| Doc | What it covers |
|-----|----------------|
| [reticulum.md](reticulum.md) | The pure‑Dart Reticulum (RNS) stack: packets, announces, hop‑by‑hop routing, identity/crypto, links, resource transfer, and the interfaces (TCP/UDP/BLE/Auto). |
| [dht.md](dht.md) | The Kademlia‑style DHT that runs over Reticulum: node IDs, k‑buckets, the RPC protocol, signed provider records, publish/resolve, and how files are **found by hash**. |
| [file-sharing.md](file-sharing.md) | Content‑addressed file hosting: how a file is referenced in chat, the decentralized resolution tiers, **find‑by‑hash vs find‑by‑text**, and how **every downloader becomes a seeder**. |
| [aprs.md](aprs.md) | The APRS transport: APRS‑IS (TNC2) framing, the wapp's connection/iGate behaviour, and how Aurora gates traffic between Bluetooth and APRS‑IS. |
| [ble.md](ble.md) | The Bluetooth transport: the size‑routed split between connectionless APRS broadcast and GATT Reticulum links, the compact frame format, the digipeater, and the store‑and‑forward iGate. |
| [aprx.md](aprx.md) | APRX — the message‑level conventions layered on plain APRS (groups, threads, reactions, signed/encrypted messages, public‑key beacons, embedded media references). |
| [mesh.md](mesh.md) | The BLE street mesh: gossip route beacons, distance‑vector routing, GATT custody transfer, store‑and‑forward, politeness backoff. |
| [folders.md](folders.md) | Mutable shared folders over Reticulum: key‑addressed directories backed by a signed, append‑only op‑log. |
| [sync.md](sync.md) | Collab (multi‑writer) folders and cross‑device sync built on top of mutable folders. |
| [nostr.md](nostr.md) | The NOSTR client wapp and its transport‑abstract relay hub (wss + Reticulum + local store). |
| [esp32.md](esp32.md) | The ESP32 dongle firmware map: project layout, which firmware is which, BLE protocol state, and the traps. |

## The big picture

```
            ┌─────────────────────────────────────────────────────────┐
            │                     Aurora chat (wapps)                  │
            │   APRX message conventions  +  file: media references    │
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
  [aprx.md](aprx.md).
- **Files** are *referenced* inside those messages by their content hash
  (`file:<sha256>.<ext>`) and *transferred* out of band over Reticulum, the DHT,
  a LAN, I2P, or BitTorrent — see [file-sharing.md](file-sharing.md).
- **Reticulum** ([reticulum.md](reticulum.md)) is the transport that lets two
  devices on different networks reach each other at all; the **DHT**
  ([dht.md](dht.md)) is the decentralized index that lets them find *who holds a
  file* without any central server.

## Identity & keys

Each station has a **Nostr keypair** (secp256k1). Every node **periodically
announces its public key on APRS‑IS** (and BLE) — a bulletin to the reserved
group `NOSTR`, **hourly, on by default**. Peers collect these into a
`callsign → public‑key` map, which is what lets them **verify signed messages**
and **encrypt 1:1 messages** to a callsign. The same key material is the
`npub`/`nsec` shown in the profile and the basis for the social relay's signed
events. Full wire detail in [aprx.md](aprx.md) §10 (announcement), §14 (signing),
§15 (encryption).

## Decentralization, in one paragraph

Finding a file is **content discovery**, and it never goes through a central
index: a holder publishes a signed "I have `<sha256>`" record into the Kademlia
DHT, and a downloader resolves the k‑closest DHT nodes to that hash to learn the
provider set. The only shared infrastructure is a Reticulum **hub** that
*relays transport packets* so two NATed phones can reach each other — it routes
bytes, it never sees or indexes content. And because every device **re‑seeds**
(publishes its own provider record) the moment it finishes a download, the set
of holders grows with each transfer. See [file-sharing.md](file-sharing.md) for
the verification of both properties against the code.
