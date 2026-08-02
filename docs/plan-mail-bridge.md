# Plan — Email ↔ Geogram bridge

> Status: design draft (2026-08-02), no code yet. Companion to `plan-mail.md`.
> Goal: let the `Mail` wapp exchange messages with the traditional email world
> while keeping geogram's key-native identity intact. A classic address like
> `alice@acme.com` must keep working the traditional way, but the **domain part
> must never be required**: identity has to survive without DNS — via key-derived
> addresses, IPv6 literals, or gateways that are disposable route hints.

## 1. Principle — identity/locator split

The canonical identity of every geogram participant is the **NOSTR pubkey**
(npub). That is already the conversation key of the Mail wapp
(`plan-mail.md` §2, `wapps/mail/main.c:328 key_to_hex()`).

The bridge extends that rule to email: **the `@domain` part of any address is a
route hint, never identity.** Every mechanism in this document is a different
way to supply — or skip — that hint:

| Mechanism | What the domain part means | Identity carried by |
|---|---|---|
| Classic SMTP | real DNS/MX domain | nothing (trust-by-domain) |
| NIP-05 resolution | lookup key for `.well-known/nostr.json` | npub (after resolve) |
| Gateway address | any live gateway, interchangeable | npub in the local part |
| IPv6 domain literal | the node's address itself | npub-DKIM header |
| Self-certifying IPv6 | hash of the node's key | the address *is* the key |
| `@geogram` pseudo-TLD | none — internal only | npub via kind-30078 resolve |

This is the same identity/locator split formalized by HIP (RFC 7401); email
just never adopted it.

## 2. Address forms accepted by the Mail wapp

The compose field accepts, in addition to today's npub/hex/base64url/callsign
(`main.c:328`):

1. **`npub1…@<gateway-domain>`** — identity in the local part; the domain names
   *some* gateway, and any gateway will do (§4). The address survives the
   death of the gateway it was first written with.
2. **`alice@acme.com`** — a classic address. Runs the resolution ladder (§3)
   before any SMTP is attempted; SMTP is the *last* resort, not the default.
3. **`user@[IPv6:2001:db8::1]`** — RFC 5321 §4.1.3 **domain literal**. Legal
   SMTP since 1982, needs no DNS and no MX record: the sender connects to the
   literal address directly. This is the standard's own escape hatch from
   domains, and it is the delivery form for domain-free endpoints (§6).
4. **`callsign@geogram`** — internal pseudo-TLD. Resolved inside the mesh
   (ladder step 3) and **never leaves geogram unrewritten**: at the SMTP
   boundary a gateway rewrites it to form 1 so the legacy world can reply.

Parsing rule: split on the last `@`; if the local part parses as an npub, the
identity is settled immediately and the domain is only a hint. Bracketed
`[IPv6:…]` / `[a.b.c.d]` literals are recognized per RFC 5321.

## 3. Resolution ladder

Applied to every address before SMTP is even considered. First hit wins; each
step downgrades trust, and only the last one leaves the key-native world:

1. **Local contact DB** — the peer is already known; use the stored pubkey and
   deliver as a normal Mail kind-4 (both lanes, `main.c:872 do_send()`).
2. **NIP-05** — fetch `https://<domain>/.well-known/nostr.json?name=<local>`.
   A hit yields the npub → deliver native kind-4 over NOSTR relays + Reticulum
   relay nodes. **SMTP is never touched.** The email address was just a lookup
   key. This is the highest-leverage piece of the whole bridge: any
   NIP-05-enabled address (already common across NOSTR) becomes reachable
   end-to-end encrypted with zero gateway infrastructure.
3. **kind-30078 relay resolve** — for `callsign@geogram` and bare callsigns.
   Already implemented end-to-end: `RnsService.publishIdentityToRelays` /
   `relayResolveCallsign` (`lib/services/reticulum/rns_service.dart:6148`,
   `:6193` — signed replaceable kind-30078, `d`-tagged by callsign, newest
   verified event wins), exposed to wapps as `hal_relay_identity_publish` /
   `hal_relay_resolve(_recv)` (`lib/wapp/wapp_engine.dart:2918`, `:2941`).
4. **Legacy SMTP via gateway** (§4) — the peer is genuinely email-only.
   Message leaves the encrypted world; the UI must say so (same visual
   language as the existing verified/forged badges).

Host placement: the ladder is generic messaging infrastructure, not Mail-wapp
logic — it belongs host-side behind a future `hal_mail_resolve`-shaped HAL
(async + `_recv` drain, same pattern as `hal_relay_resolve`), keeping the wapp
free of HTTP and DNS concerns.

## 4. Stateless federated gateways

A gateway is any internet-reachable node that volunteers to speak SMTP on
behalf of the mesh — the exact social contract of the APRS iGate, applied to
email.

**The gateway holds no accounts.** That is the design's load-bearing property:

- **Inbound**: gateway SMTP-receives `npub1…@gw.tld`, parses the npub out of
  the local part, wraps body + metadata as a kind-4 DM to that npub, and
  delivers it over the existing two lanes (`hal_nostr_dm_send` +
  `hal_relay_dm_send` equivalents, host-side). It needs no user database,
  no signup, no state beyond spam throttling. Consequently **any gateway can
  serve any npub**, and a gateway dying loses nothing — the same local part
  works at the next gateway. The published "geogram email address" of a user
  is therefore *a set*: `npub1…@{gw1.tld, gw2.tld, …}`, and senders may use
  whichever member answers.
- **Outbound**: a mesh node composing to a legacy address hands the message to
  store-and-forward (existing relay-node mailbox semantics); the first
  gateway that sees it submits via SMTP. Gateways sign with their *own*
  domain DKIM/SPF purely to appease receiving spam filters — domain
  reputation is a transport concern, not identity (§5 carries identity).
  `From:` is `npub1…@<that-gateway>` so replies route back through form 1.
- **Loop/dedup**: the Mail wapp's envelope id (`rmid`, `main.c:730 env_wrap`
  / `:774 ingest()` dedup ring) rides in an `X-Geogram-Rmid` header, so a
  message crossing the bridge twice (e.g. two gateways both submitting) still
  collapses to one on either side.

**Where the gateway code lives — deliberately deferred.** Two options, to be
decided when the gateway phase starts:

| | Standalone daemon | aurora host HAL (`hal_smtp_*`) |
|---|---|---|
| Fits | keep-host-generic; hubs run it headless | any phone with internet becomes a gateway |
| Cost | separate deploy/update story | SMTP server + DNS probing inside the app core |
| Port 25 | fine on a VPS hub | blocked on residential/mobile networks — outbound submission only |

Either way, the implementation is a **port, not a rewrite**: the predecessor
repo carries a complete, working stack — `geogram/lib/services/smtp_server.dart`
(real EHLO state machine), `smtp_client.dart`, `email_dns_service.dart`
(MX/SPF/DKIM/DMARC probing), `util/dkim_signer.dart`, and the 1495-line
`geogram/docs/apps/email-format-specification.md`. Its `localPart@station`
addressing is superseded by this document; the protocol machinery is reusable.

## 5. npub-DKIM — end-to-end authorship, independent of transport

Every bridged email carries the sender's key identity in headers:

```
X-Geogram-Npub: npub1…
X-Geogram-Sig:  <base64 Schnorr signature>
X-Geogram-Rmid: <envelope id>
```

- **Canonicalization**: DKIM-style *relaxed* over a fixed header list
  (`From`, `To`, `Subject`, `Date`, `Message-ID`, `X-Geogram-Npub`,
  `X-Geogram-Rmid`) plus the body hash — reuse DKIM's exact relaxed rules so
  the signature survives the whitespace/wrapping mangling that real MTAs and
  forwarders inflict.
- **Verification**: a geogram recipient (or gateway ingesting inbound mail)
  verifies the Schnorr signature against the npub and shows the existing
  verified/forged badge. The transport path — Gmail, mailing-list forwarders,
  any number of hops — becomes irrelevant to authorship. Domain DKIM remains
  a gateway-local spam formality.
- **Precedent in-tree**: the APRX `~sig` scheme already does short-Schnorr
  signing host-side with the same badge semantics; this is the same idea with
  DKIM canonicalization instead of APRS framing.

## 6. Domain-free endpoints (later phase, exploratory)

1. **IPv6 domain literals** — a node with a public IPv6 address runs an SMTP
   listener and is reachable as `user@[IPv6:…]` with zero DNS. Standard, works
   today against most MTAs; caveat: some large providers refuse to *send* to
   literals, so this complements rather than replaces gateways.
2. **Self-certifying IPv6** — derive the address from the node key so the
   locator itself is verifiable:
   - **Yggdrasil** (`200::/7`) / **cjdns** (`fc00::/8`): mesh-routed IPv6
     where the address is a hash of the node's public key. A `yggdrasil-dart`
     node is a real candidate given the existing pure-Dart I2P and Reticulum
     stacks in this tree.
   - **CGA** (RFC 3972): the same property on plain IPv6, no overlay network.

   Endpoint form `npub1…@[IPv6:200:…]` then has *both* halves cryptographic:
   the local part names the author key, the literal names (and proves) the
   endpoint key. No registry, no DNS, no gateway anywhere in the path.

## 7. Interop details

- **Threading**: map `Message-ID` ↔ NOSTR event id bidirectionally. Outbound:
  `Message-ID: <event-id@geogram.invalid>`; inbound: carry the original
  `Message-ID`/`In-Reply-To` in event tags so replies thread on both sides.
- **Content**: `text/plain` body ↔ kind-4 content. MIME attachments become the
  existing `file:<sha256>.<ext>` media-ref tokens backed by the host
  MediaArchive; a gateway serves/fetches the blobs at its HTTP side.
- **Dedup**: `rmid` is the single cross-world envelope id (§4).
- **Encryption honesty**: a message that traverses SMTP in the clear must
  never render with the lock badge. Ladder step 4 is the only unencrypted
  path, and the UI states it.

## 8. Prior art

- **I2P-Bote** — serverless encrypted mail: key-hash addresses, DHT-stored
  mail, no accounts anywhere. The closest existing system to §4+§6 combined.
- **HIP** (RFC 7401) — the identity/locator split as an IETF standard: host
  identity is a public key, IP addresses are transient locators.
- **NIP-05** — DNS-based verification mapping `name@domain` → npub; the
  bridge inverts its usual use: not to verify a key, but to *route around*
  SMTP entirely.
- **RFC 5321 §4.1.3** — address literals; RFC 3972 — CGA; Yggdrasil/cjdns —
  key-derived overlay IPv6.

## 9. Phasing

1. **DONE (2026-08-02)** — Resolution foundation:
   - `EmailResolveService` (aurora `lib/services/social/email_resolve_service.dart`):
     ladder = local store → mesh rendezvous query → live NIP-05 fetch with
     kind-0 cross-check; result published as a signed kind-30078
     `d=mailto:<email>` mapping (`RnsService.publishMailtoMapping`).
   - Public WS relay: `NostrWsServer` hardened (same SpamPolicy/tier/admission
     as the RNS door, kind-4 excluded, NIP-11 doc with pubkey) and wired for
     live push via `RelayEventStore.onPut`; a REQ for `#d mailto:…` with no
     stored answer triggers the resolver and the mapping arrives on the open
     sub after EOSE. Prefs: `nostr.wsRelay` (on), `nostr.wsRelay.port` (4848).
   - Mail wapp 0.3.1 compose accepts email addresses via the unchanged
     `hal_relay_resolve` ABI ('@' routes host-side); unverified mappings are
     labelled. New **Email screen** (settings): set my address, Verify checks
     the domain lists this device's key and reports rendezvous-relay routing;
     the `nip05:<email>` resolve form forces a live domain check (skips
     negative cache and store/mesh rungs) so a just-fixed nostr.json verifies
     immediately.
2. npub-DKIM header spec + verification (badge) — gateway-independent.
3. Inbound gateway (stateless), then outbound submission — location decision
   from §4 made here.
4. Domain-free endpoints (§6) — after gateways prove the mapping.
