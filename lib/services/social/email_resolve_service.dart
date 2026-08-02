/*
 * EmailResolveService — turns a classic email address into a NOSTR pubkey.
 *
 * The bridge principle (docs/plan-mail-bridge.md): identity is ALWAYS the
 * npub; `alice@acme.com` is just a lookup key. The ladder, first hit wins:
 *   1. local relay store — a stored kind-30078 `d=mailto:<email>` mapping
 *   2. mesh — the same query fanned to rendezvous relay dests (offgrid path)
 *   3. live NIP-05 — https://<domain>/.well-known/nostr.json?name=<local>,
 *      cross-checked against the target's kind-0 `nip05` field, then published
 *      as a signed mapping event so the whole mesh learns it
 *   4. miss → negative-cached ~10 min (WS REQ retries must not hammer HTTPS)
 *
 * Result shape is EXACTLY what RnsService.relayResolveCallsign returns
 * ({callsign, npub(base64url), deliv, prop}) so hal_relay_resolve_recv and the
 * Mail wapp's resolve_drain work unchanged — the email rides the `callsign`
 * field as the display alias. Adds `kind0_match` for the verified badge.
 *
 * MAIN ISOLATE ONLY. The kind-0 cross-check opens one-shot WebSockets exactly
 * like NostrAllPoller (open → REQ → bounded wait → close): the engine isolate
 * freezes when it reopens sockets, so nothing here may run there.
 */
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart'
    show
        NostrEvent,
        NostrEventKind,
        NostrFilter,
        NostrWsClient,
        kDefaultNostrRelays;

import '../../connections/internet/http_transport.dart';
import '../log_service.dart';
import '../reticulum/rns_service.dart';

class EmailResolveService {
  EmailResolveService._();
  static final EmailResolveService instance = EmailResolveService._();

  static const Duration _httpTimeout = Duration(seconds: 10);
  static const Duration _kind0Collect = Duration(seconds: 4);
  static const Duration _negativeTtl = Duration(minutes: 10);
  static const int _maxKind0Relays = 4;

  /// One resolution per address at a time; concurrent callers share the future.
  final Map<String, Future<Map<String, dynamic>?>> _inFlight = {};

  /// Recent misses (email → expiry ms) so repeated REQs don't re-fetch.
  final Map<String, int> _negativeUntil = {};

  /// Resolve [email] → `{callsign:<email>, npub, deliv, prop, kind0_match}`
  /// or null. [relayDestsHex] overrides the mesh rendezvous set (the wapp
  /// passes its own); absent, dests are picked by rendezvous-hashing the
  /// email itself so every device asks the same relays for the same address.
  ///
  /// [freshNip05] skips the negative cache AND the store/mesh rungs, going
  /// straight to the domain — the Email-settings Verify button uses it so a
  /// just-fixed nostr.json is seen immediately (and a stale stored mapping
  /// can't shadow the live listing). Ordinary sends keep the full ladder.
  Future<Map<String, dynamic>?> resolve(
    String email, {
    List<String>? relayDestsHex,
    bool freshNip05 = false,
  }) {
    final addr = email.trim().toLowerCase();
    if (splitEmail(addr) == null) return Future.value(null);
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = _negativeUntil[addr];
    if (!freshNip05 && until != null && now < until) return Future.value(null);
    return _inFlight.putIfAbsent(addr, () async {
      try {
        final r = await _resolve(addr, relayDestsHex, freshNip05: freshNip05);
        if (r == null) {
          _negativeUntil[addr] =
              DateTime.now().millisecondsSinceEpoch + _negativeTtl.inMilliseconds;
        } else {
          _negativeUntil.remove(addr);
        }
        return r;
      } finally {
        // ignore: unawaited_futures
        Future<void>.delayed(Duration.zero, () => _inFlight.remove(addr));
      }
    });
  }

  Future<Map<String, dynamic>?> _resolve(
    String addr,
    List<String>? relayDestsHex, {
    bool freshNip05 = false,
  }) async {
    final rns = RnsService.instance;
    final filter = NostrFilter(
      kinds: const [NostrEventKind.applicationSpecificData],
      tags: {
        'd': ['mailto:$addr'],
      },
      limit: 4,
    );

    if (!freshNip05) {
      // 1. Local store.
      var best =
          _pickMapping(rns.relayStore?.query(filter) ?? const [], addr);
      if (best != null) return _result(addr, best);

      // 2. Mesh rendezvous. Hashing the address itself gives every device the
      // same relay set for the same email — publisher and resolver meet.
      final dests = relayDestsHex ??
          rns.relayDestsFor(
              crypto.sha256.convert(utf8.encode(addr)).toString());
      if (dests.isNotEmpty) {
        final fromMesh = await rns.relayQueryDests(filter, dests);
        best = _pickMapping(fromMesh, addr);
        if (best != null) return _result(addr, best);
      }
    }

    // 3. Live NIP-05 (internet devices only — a network throw is just a miss).
    final nip05 = await _fetchNip05(addr);
    if (nip05 == null) return null;
    final (pubHex, relayHints) = nip05;
    final kind0Match = await _kind0Matches(pubHex, addr, relayHints);
    // Attest either way; consumers prefer kind0_match=true mappings.
    await rns.publishMailtoMapping(
        email: addr, pubHex: pubHex, kind0Match: kind0Match);
    return {
      'callsign': addr,
      'npub': _hexToB64url(pubHex) ?? '',
      'deliv': '',
      'prop': '',
      'kind0_match': kind0Match,
    };
  }

  /// Newest verified mapping event whose d-tag names [addr], or null.
  NostrEvent? _pickMapping(List<NostrEvent> events, String addr) {
    NostrEvent? best;
    for (final ev in events) {
      if (!ev.preVerified && !ev.verify()) continue;
      final d = 'mailto:$addr';
      if (!ev.tags.any((t) => t.length >= 2 && t[0] == 'd' && t[1] == d)) {
        continue;
      }
      if (best == null || ev.createdAt > best.createdAt) best = ev;
    }
    return best;
  }

  Map<String, dynamic>? _result(String addr, NostrEvent mapping) {
    try {
      final m = jsonDecode(mapping.content);
      if (m is! Map) return null;
      final npub = _hexToB64url((m['npub'] ?? '').toString());
      if (npub == null) return null;
      return {
        'callsign': addr,
        'npub': npub,
        'deliv': '',
        'prop': '',
        'kind0_match': m['kind0_match'] == true,
      };
    } catch (_) {
      return null;
    }
  }

  /// NIP-05 lookup: returns (pubkeyHex, relayHints) or null.
  Future<(String, List<String>)?> _fetchNip05(String addr) async {
    final parts = splitEmail(addr);
    if (parts == null) return null;
    final (local, domain) = parts;
    try {
      final rsp = await HttpTransport.shared.get(
        Uri.https(domain, '/.well-known/nostr.json', {'name': local}),
        headers: const {'Accept': 'application/json'},
        timeout: _httpTimeout,
      );
      if (!rsp.isOk) return null;
      return parseNip05Json(rsp.bodyString, local);
    } catch (e) {
      LogService.instance.add('mail/resolve: nip05 $domain: $e');
      return null;
    }
  }

  /// Does [pubHex]'s kind-0 profile claim [addr] as its nip05? Store first,
  /// else a one-shot internet fetch (NostrAllPoller discipline: bounded, then
  /// every socket closed).
  Future<bool> _kind0Matches(
    String pubHex,
    String addr,
    List<String> relayHints,
  ) async {
    final stored = RnsService.instance.relayStore?.profileOf(pubHex);
    var profile = stored;
    if (profile == null) {
      final relays = <String>{
        ...relayHints.where((u) => u.startsWith('ws')),
        ...kDefaultNostrRelays,
      }.take(_maxKind0Relays);
      final clients = <NostrWsClient>[];
      NostrEvent? found;
      for (final uri in relays) {
        final c = NostrWsClient(uri);
        clients.add(c);
        c.onEvent = (sub, ev) {
          if (ev.kind == NostrEventKind.setMetadata &&
              ev.pubkey == pubHex &&
              ev.verify() &&
              (found == null || ev.createdAt > found!.createdAt)) {
            found = ev;
          }
        };
        // ignore: discarded_futures
        c.connect().then((_) {
          c.subscribe('k0', [
            NostrFilter(
                kinds: const [NostrEventKind.setMetadata],
                authors: [pubHex],
                limit: 1),
          ]);
        }).catchError((_) {});
      }
      await Future<void>.delayed(_kind0Collect);
      for (final c in clients) {
        // ignore: discarded_futures
        c.close();
      }
      profile = found;
    }
    if (profile == null) return false;
    try {
      final m = jsonDecode(profile.content);
      if (m is! Map) return false;
      return (m['nip05'] ?? '').toString().trim().toLowerCase() == addr;
    } catch (_) {
      return false;
    }
  }

  /// `(local, domain)` for a valid NIP-05-shaped address, else null. Local
  /// part per NIP-05: a-z 0-9 - _ . (the `_` root name included).
  static (String, String)? splitEmail(String addr) {
    final at = addr.lastIndexOf('@');
    if (at <= 0 || at == addr.length - 1) return null;
    final local = addr.substring(0, at);
    final domain = addr.substring(at + 1);
    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(local)) return null;
    if (!RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(domain)) return null;
    return (local, domain);
  }

  /// Parse a nostr.json body; returns (pubkeyHex, relayHints) for [local].
  static (String, List<String>)? parseNip05Json(String body, String local) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final names = j['names'];
      if (names is! Map) return null;
      final pub = (names[local] ?? '').toString().toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pub)) return null;
      final hints = <String>[];
      final relays = j['relays'];
      if (relays is Map) {
        final list = relays[pub];
        if (list is List) {
          hints.addAll(list.map((e) => e.toString()));
        }
      }
      return (pub, hints);
    } catch (_) {
      return null;
    }
  }

  /// 64-hex x-only pubkey → the wapp's base64url no-pad pk-store form.
  static String? _hexToB64url(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
    final bytes = <int>[
      for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)
    ];
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
