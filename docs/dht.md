# The file DHT — finding *who has a file*, with no central server

Aurora finds the providers of a content‑addressed file through a **Kademlia‑style
distributed hash table** that runs *over* Reticulum links. The code is in
[`lib/services/files/dht/`](../lib/services/files/dht/) and the node that drives
it is `FileTransferNode` ([`file_node.dart`](../lib/services/files/file_node.dart)).

This is the **find‑by‑hash** mechanism. (Find‑by‑*text* is a separate relay
index — see [file-sharing.md](file-sharing.md) §6.)

> **Why a DHT and not a server?** A provider record says "identity *P* holds file
> *H*". Storing those records at the DHT nodes *closest to H* means any node can
> find the holders of *H* by walking toward *H* in the keyspace — no node has the
> global picture, no server is privileged, and a provider that disappears simply
> stops republishing and ages out.

---

## 1. Keyspace, node IDs, distance

- **128‑bit keyspace**, matching Reticulum's destination‑hash width
  (`kDhtIdLen = 16`, `dht_core.dart`).
- A **node ID** is the node's RNS destination hash for the `geogram/dht`
  destination (`DhtContact.ofIdentity`).
- A **file's key** is the first 128 bits of its SHA‑256: `dhtFileKey(sha256) =
  sha256[:16]`.
- **Distance** is XOR, compared big‑endian (`dhtXor`, `dhtCompare`). The
  bucket index is the number of leading zero bits of the distance — closer nodes
  share a longer prefix.

## 2. Routing table — k‑buckets (`routing_table.dart`)

128 buckets (one per bit), each holding up to **k = 8** contacts in
least‑recently‑seen → most‑recently‑seen order. On a full bucket the existing,
proven‑live contacts are kept and the newcomer is dropped (conservative under
churn; stale eviction is a noted future refinement).

## 3. RPC protocol (`dht_message.dart`)

A compact **binary** encoding (not JSON/msgpack). Every message carries the
sender's 64‑byte public key so the receiver can learn it as a contact:

```
[op:1] [senderPub:64] [payload…]
```

| Op | Code | Payload | Response |
|----|------|---------|----------|
| `PING` | 0x01 | — | `PONG` (0x81) |
| `FIND_NODE` | 0x02 | target id (16 B) | `NODES` (0x82): up to N×64‑byte pubkeys |
| `FIND_VALUE` | 0x03 | sha256 (32 B) | `VALUE` (0x83): provider records **or** nodes |
| `STORE` | 0x04 | provider record | `STORE_OK` (0x84): bool |

Replies are capped to fit **one ~450 B link‑encrypted packet** — at most 5
contacts or 2 records per reply (`kDhtWireMaxContacts`, `kDhtWireMaxRecords`) —
so no per‑RPC fragmentation is needed; the routing table still uses the full
k=8 internally.

## 4. Transport binding — DHT over Reticulum links (`file_node.dart`)

Each RPC is a short‑lived **Reticulum link** to the peer's `geogram/dht`
destination:

```
_dhtRpcRaw(peer, reqBytes):
  link = RnsLink.initiator(peer, "aurora", ["dht"])
  link.nextHop = nextHopFor(peer)         // route via the learned hub if needed
  send(link.buildRequest())               // LINKREQUEST
  …on proof, send link.encrypt(reqBytes)  // the DHT message, encrypted
  await one encrypted reply (8 s timeout)
```

The responder side (`_acceptDhtLink` / `_onDhtServePacket`) accepts the link,
decrypts the request, hands it to `DhtNode.handleEncoded`, and returns the
encrypted response on the same link. So **every DHT message is end‑to‑end
encrypted** and addressed to a public‑key destination — there is no plaintext
tracker.

## 5. Provider records (`provider_record.dart`)

A signed "I provide this file" record:

```
{ sha256(32), providerPub(64), capacity, manifestHash?(32),
  timestampMs, ttlSec, signature(64) }
```

- **Signed (Ed25519) by the provider's identity** — any node can verify it
  without trusting whoever relayed it. (And since downloads are hash‑verified, a
  lying record costs only a wasted round trip.)
- Carries the provider's **public key**, which is both the verification key *and*
  the address to reach its `geogram/files` destination.
- **TTL = 2700 s (45 min)**; republished **every 30 min** (`rns_service.dart`).
  Abrupt departures self‑heal: a record nobody republishes simply expires.
- **Capacity class** (archive / home‑fibre / home‑wifi / wifi‑transient /
  cellular / BLE / unknown) lets resolvers prefer always‑on holders over a phone
  that may vanish.

## 6. Publish — becoming a provider (`DhtNode.publish`)

```
publish(record):
  closest = iterativeFindNode(record.fileKey)   // k nodes nearest the file key
  for c in closest: STORE(record) → count STORE_OK
  if closest empty: store locally (tiny/isolated network)
```

`FileTransferNode.publishProvider(sha256)` builds and signs the record then
publishes it, **and remembers it for the 30‑minute republish loop**. It is gated
by the serve quota: a node that can't currently serve doesn't advertise, so
resolvers route around it until it recovers.

Exposed to the app as `RnsService.dhtPublish(fileHash)`. This is called when you
**attach** a file *and* — now — whenever you **finish downloading** one (see
[file-sharing.md](file-sharing.md) §5), which is what makes every holder a
seeder.

## 7. Resolve — finding providers (`DhtNode.resolve`)

```
resolve(sha256):
  target = sha256[:16]
  seed found{} with any live local records
  iterate (α=3 in parallel, up to 24 rounds):
    FIND_VALUE(sha256) to the closest unqueried contacts
    on VALUE: verify signature, drop expired/mismatched, dedup by providerPub
    on NODES: add to the shortlist, keep walking toward target
  return providers sorted by capacity (best first)
```

The iterative lookup converges in roughly **log₂(N)** rounds (typically 3–4) —
each round queries α=3 nodes concurrently and stops once the k closest have all
answered. `FileTransferNode.resolveAndFetch` then does a **multi‑source**
download from several providers in parallel and verifies the bytes against the
hash.

Exposed as `RnsService.dhtResolveFetch(fileHash)`.

## 8. Bootstrapping & membership — "which nodes run our DHT?"

There is no dedicated bootstrap server, and there is no global registry of "Aurora
nodes". This raises a real question, because **Aurora is (currently) the only
overlay running a DHT on Reticulum** — a public hub is full of Sideband,
NomadNet and `rnsd` identities that do *not* run it. How does a node tell which
peers can actually answer a DHT RPC?

**The answer is the destination name, proven by the signed announce.** Every
Reticulum announce advertises a *named destination* and is Ed25519‑signed; the
destination hash cryptographically binds the name to the announcing identity
(`dest_hash = sha256(name_hash || identity_hash)[:16]`, see
[reticulum.md](reticulum.md) §2). An Aurora node announces a destination named
**`geogram/dht`** (`_announceServiceDests` in `rns_service.dart`). No other software
announces that name, so its `name_hash` is unique to our overlay.

So membership is a wire test, not a guess (`rns_service.dart`, `_onInbound`):

```dart
final dhtHash = RnsDestination.hash(ann.identity, 'aurora', ['dht']);
if (RnsCrypto.constantTimeEquals(ann.destHash, dhtHash)) {
  _files?.addPeerFromAnnounce(ann.identity);   // confirmed Aurora DHT node
}
```

A peer is added to the routing table **only** when we hear its signed
`geogram/dht` announce — the destHash matches the hash we recompute from the
announcing identity, so a non‑Aurora node (which never announces that name) is
never added, and nobody can forge membership for an identity they don't hold the
key to. Every Aurora node re‑announces its service destinations on an adaptive
cadence (30 s when charging on Wi‑Fi/Ethernet, 5 min on battery/cellular — see
[reticulum.md](reticulum.md) §3), so the table fills within one announce cycle of
a peer coming into view; on a hub
with no other Aurora nodes the table simply stays empty and `resolve` returns
nothing immediately (we then fall back to a direct fetch from the sender, §9)
instead of timing out on dead contacts.

> Earlier the code added *every* announced identity optimistically and relied on
> the 8‑second RPC timeout to prune non‑members. That worked but wasted lookup
> rounds on a populated public hub; gating on the `geogram/dht` announce makes the
> routing table contain only confirmed overlay nodes.

The same pattern identifies peers for the other overlays — the relay
(`geogram/relay`), LXMF (`lxmf/delivery`), files (`geogram/files`) — each by its own
announced destination name.

## 9. Honest limitations

- **Reply size caps** (5 contacts / 2 records per packet) mean wide result sets
  take extra rounds; there is no multi‑packet framing yet.
- **Stale eviction** is conservative — a dead contact lingers in its bucket until
  displaced.
- **On a large *foreign* public testnet**, the XOR‑closest nodes to a file key
  are reference RNS nodes that don't run this overlay and ignore the STORE/FIND
  RPCs. That's exactly why file resolution tries a **direct fetch from the
  sender** first (the sender is, by definition, a holder, and you already learned
  its route from its chat announce) before relying on the DHT. Among Aurora nodes
  that *do* form the overlay, the DHT is the discovery mechanism.
