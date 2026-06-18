# Reticulum (RNS) — Aurora's pure‑Dart implementation

Aurora ships a **wire‑compatible, pure‑Dart implementation of Reticulum 1.3.5**
([markqvist/Reticulum](https://github.com/markqvist/Reticulum)). It interoperates
with a reference `rnsd` and with Sideband/NomadNet over the same hubs. All code
lives in [`lib/services/reticulum/`](../lib/services/reticulum/).

Reticulum gives Aurora three things the internet alone doesn't:

1. **Reachability across networks** — two phones behind carrier‑grade NAT can
   exchange data by both connecting *outbound* to a shared hub that relays
   between them.
2. **End‑to‑end encryption by destination** — every destination is a public key;
   you address bytes to a hash, and only the holder of the matching private key
   can read them.
3. **Transport independence** — the same packets ride TCP, UDP, BLE, or a
   zero‑config LAN interface.

> **What Reticulum is *not* here:** it is not the content index. Finding *who
> has a file* is the DHT's job ([dht.md](dht.md)). Reticulum just moves the
> bytes and the DHT RPCs.

---

## 1. Architecture

`RnsService` (`rns_service.dart`) is the singleton that owns the stack:

- a node **identity** (`RnsIdentity`, a Curve25519 + Ed25519 keypair, persisted
  to `rns_identity.key`),
- a **transport** (`RnsTransport`) — the route table + announce ingestion +
  forwarding,
- a list of **interfaces** (`RnsInterface`) — TCP client/server, UDP, BLE, Auto,
- and the higher‑level nodes built on top: `FileTransferNode` (files + DHT),
  `LxmfRouter` (LXMF messaging), `RelayNode` (social/text search).

Startup is split so the long‑lived pieces survive a flaky network
(`rns_service.dart` init path): the identity, transport and the file/LXMF/relay
nodes are built **once**; each (re)connection only rebinds the network
interface. The node is configured as a **transport node**, i.e. it rebroadcasts
announces between interfaces, so devices on different segments (BLE ↔ LAN ↔ hub)
can discover one another.

`ensureRnsAutostart()` (`rns_autostart.dart`) wires the persistent stores (media
archive as the file‑serve source, relay/folder DBs, identity) and connects to
the configured bootstrap hubs in turn until one answers. After connecting it
**announces itself and waits up to 8 s for any valid inbound announce** — a
wrong endpoint (e.g. a plain web server) can never produce an Ed25519‑signed
announce, so this proves the link really speaks Reticulum. A 30 s timer retries
if the node ever drops.

---

## 2. Packet format (`rns_packet.dart`)

```
HEADER_1: flags(1) hops(1) dest_hash(16) context(1) data…
HEADER_2: flags(1) hops(1) transport_id(16) dest_hash(16) context(1) data…
```

`HEADER_2` carries an extra 16‑byte **transport_id** (the relay the packet is
travelling through). The `flags` byte packs five fields:

```
(header_type<<6) | (context_flag<<5) | (transport_type<<4) | (dest_type<<2) | packet_type
```

- **header_type** — HEADER_1 vs HEADER_2
- **context_flag** — set when an announce carries a ratchet key
- **transport_type** — broadcast (direct) vs transport (through a relay)
- **dest_type** — `SINGLE` / `GROUP` / `PLAIN` / `LINK`
- **packet_type** — `DATA` / `ANNOUNCE` / `LINKREQUEST` / `PROOF`

The **context** byte selects the sub‑protocol on a link, e.g. `RESOURCE`,
`RESOURCE_ADV`, `RESOURCE_REQ`, `RESOURCE_PRF` (resource transfer), `LRPROOF`
and `LRRTT` (link establishment).

### Destination hashes

A destination is identified by a 16‑byte hash derived from a *name* and an
*identity* (`rns_identity.dart`):

```
name_hash     = sha256("app.aspect1.aspect2…")[:10]
identity.hash = sha256(x25519_pub || ed25519_pub)[:16]
dest_hash     = sha256(name_hash || identity.hash)[:16]
```

Aurora uses distinct destinations for distinct services on the same identity,
e.g. `geogram.chat`, `geogram/files`, `geogram/dht` — so file transfers, DHT RPCs
and chat each get their own addressable endpoint.

---

## 3. Announces (`rns_announce.dart`)

An announce is a **signed, broadcast advertisement** of a destination. Wire:

```
data        = public_key(64) name_hash(10) random_hash(10) [ratchet(32)] signature(64) [app_data]
signed_data = dest_hash public_key name_hash random_hash [ratchet] app_data
```

- `public_key` is the 64‑byte `x25519_pub || ed25519_pub`.
- `random_hash` is 5 random bytes + 5 big‑endian bytes of the Unix time — a
  freshness nonce, not pure randomness.
- the signature is **Ed25519** over `signed_data`.
- `app_data` is free‑form; Aurora puts the **device callsign** here, which is how
  a chat peer learns a callsign → RNS‑destination mapping.

The transport validates an announce in two stages:

1. **Cheap binding check** (always): `dest_hash` must equal
   `sha256(name_hash || identity_hash)[:16]`. This is enforced even when the
   signature check is skipped.
2. **Ed25519 signature** over `signed_data`. A *trust cache* lets an unchanged
   re‑announce of a known destination skip the expensive verify.

Each relay that forwards an announce **increments the `hops` field by one**. The
signature doesn't cover `hops`, so a relayed announce is byte‑identical except
for that field and the added `transport_id` in HEADER_2.

**Re‑announce cadence (adaptive).** The first announce is immediate (on connect);
the periodic refresh then adapts to the device's situation, re‑reading the
power/network state each cycle (`_scheduleAnnounce` in `rns_service.dart`):

| Situation | Interval |
|-----------|----------|
| Charging **and** on Wi‑Fi/Ethernet (a good always‑on citizen, incl. desktops) | **30 s** |
| On battery, or on cellular/metered | **5 min** |

This keeps a plugged‑in node responsive while sparing phone batteries and
low‑bandwidth links from needless traffic. (The signal comes from
`CapacityGovernor`, which already drives the file‑serving capacity class.)

---

## 4. Routing / transport (`rns_transport.dart`)

Reticulum routing is **hop‑by‑hop shortest‑path, announce‑driven** — *not*
onion routing, and *not* a DHT (the file DHT in [dht.md](dht.md) is a separate
overlay that *uses* this transport).

The path table keeps, per destination hash: the identity, hop count, the
interface it was heard on (`via`), and an optional `nextHop` (the 16‑byte
transport_id to address future packets through when the destination is reached
via a relay).

- **Ingest** dedups by packet hash (kills announce loops), validates announces,
  and updates the path table keeping the **lowest hop count**.
- **Forward**: a data packet for a known remote destination is rebuilt with
  updated hops and sent as HEADER_1 (direct neighbour) or HEADER_2 (through the
  stored `nextHop`).
- **Rebroadcast**: announces are re‑emitted on every interface except the one
  they arrived on, with this node's transport_id, so the overlay learns paths.
- **Unknown destinations**: data packets are dropped — Reticulum favours
  periodic announces over path‑request flooding.

Transit **links** (a point‑to‑point link between two leaf nodes bridged by a
hub) are tracked by link‑id: when a `LINKREQUEST` passes through, the transport
remembers which two interfaces bridge it and routes the subsequent
`LRPROOF`/`LRRTT`/`DATA` packets both ways.

---

## 5. Identity & crypto (`rns_identity.dart`, `rns_crypto.dart`)

| Primitive | Use |
|-----------|-----|
| **X25519** | ECDH for link keys and identity encryption |
| **Ed25519** | signing announces and link proofs |
| **HKDF‑SHA256** (RFC 5869) | key derivation |
| **AES‑256‑CBC + PKCS7** | symmetric encryption (the "token") |
| **HMAC‑SHA256** | authenticating ciphertext |
| **SHA‑256 / truncated hash** | hashes, destination derivation |

An identity is `{x25519 priv/pub, ed25519 priv/pub}`; its 16‑byte `hash` is
`sha256(x25519_pub || ed25519_pub)[:16]`.

**Identity encryption** (`Identity.encrypt`) does an ephemeral ECDH to the
destination's X25519 public key, HKDFs a 64‑byte key (32 signing + 32
encryption) salted with the identity hash, then emits
`eph_pub(32) || iv(16) || AES256CBC(plaintext) || HMAC`. This is byte‑for‑byte
the reference RNS "token" construction.

---

## 6. Links (`rns_link.dart`)

A **Link** is an encrypted, authenticated session between two destinations,
established with a 3‑packet handshake:

1. **LINKREQUEST** — the initiator sends ephemeral X25519 + Ed25519 public keys.
   The `link_id` is `truncated_hash` of the request body (signalling bytes
   excluded, so it's identical whether the request was direct or relayed).
2. **LRPROOF** — the responder signs `link_id || its_eph_x25519 || its_dest_ed_pub`
   and returns it; the initiator verifies.
3. **LRRTT** — the initiator sends an encrypted round‑trip‑time probe, which
   activates the link on the responder.

Both sides derive the same session key: `HKDF(X25519(eph), salt=link_id)` →
the 64‑byte token (AES‑256‑CBC + HMAC). All subsequent `DATA` packets on the
link are token‑encrypted. Links are how DHT RPCs and file transfers are carried.

---

## 7. Resource transfer (`rns_resource.dart`, `rns_resource_receiver.dart`)

A **Resource** moves a payload larger than one packet over a Link — this is the
mechanism that ships file bytes.

**Sender:** prepends 4 random bytes, encrypts the whole stream with the link
token, splits it into `resourceSdu`‑byte parts (≈464 B at MTU 500), computes a
per‑part `map_hash = sha256(part || map_random)[:4]`, and **advertises** a
msgpack map of `{transfer_size, part_count, resource_hash, map_random, hashmap}`
(context `RESOURCE_ADV`). It then ships the parts the receiver requests
(`RESOURCE_REQ` → `RESOURCE`), and validates the receiver's completion
**proof**.

**Receiver:** ingests the advertisement, requests missing parts by map‑hash,
reassembles, decrypts, and verifies `sha256(payload || map_random) ==
resource_hash` before returning the bytes and sending its proof.

> **Caveat (real‑world):** the hashmap fits **74 parts per advertisement**
> (≈32 KB per segment), and there is a fixed link + advertise + request round‑trip
> overhead, so even small files take on the order of tens of seconds over a
> multi‑hop public hub. This is why file sharing tries a **direct fetch from the
> sender** before falling back to the DHT (see [file-sharing.md](file-sharing.md)).

---

## 8. Interfaces

| Interface | File | Notes |
|-----------|------|-------|
| **TCP client** | `rns_tcp_interface.dart` | Connects outbound to a hub / `rnsd`. HDLC‑framed. |
| **TCP server** | `rns_tcp_server_interface.dart` | Binds a port (default `:4242`); each client becomes an interface, so the host acts as a **hub** that rebroadcasts announces between clients. |
| **UDP** | `rns_udp_interface.dart` | One raw RNS packet per datagram (no HDLC). LAN. |
| **BLE** | `rns_ble_interface.dart` | Broadcasts packets that fit the connectionless cap; falls back to GATT unicast for larger ones. See [ble.md](ble.md). |
| **Auto** | `rns_auto_interface.dart` | Zero‑config IPv6 link‑local peering: nodes multicast `sha256(group_id || own_address)`; a peer that recomputes the token from the observed source address is accepted. |

**HDLC framing** (`rns_hdlc.dart`) wraps TCP/serial packets as
`0x7E … 0x7E` with `0x7E`/`0x7D` byte‑stuffing; the deframer is stateful to
handle packets split across reads.

---

## 9. What's wire‑compatible, what's Aurora‑specific

- **Wire‑compatible with reference RNS:** packet/announce/link/resource formats,
  all crypto, hop‑by‑hop routing, HDLC, the Auto/local interface.
- **Aurora‑specific (built *on* RNS, still over standard links/packets):** the
  file DHT ([dht.md](dht.md)), the LXMF router (`lxmf/`), and the social relay
  (`social/`). These define their own destinations/aspects (`geogram/dht`,
  `geogram/files`, …) and ride normal Reticulum links, so a reference RNS node
  relays them transparently even though it doesn't understand the overlay.
