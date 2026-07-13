import 'dart:async';
import 'dart:convert';

import 'package:reticulum/reticulum.dart';


import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'keep_policy.dart';

/// "To touch it is to keep it" — the host half of the touch rule
/// (docs/NOSTR.md, *The bridge*).
///
/// A like is not a fleeting gesture: it is a statement that this thing mattered.
/// So when the user likes, replies to, reposts, bookmarks or zaps an event, the
/// EVENT is archived here — the note itself, its author's profile, the thread
/// above a reply, and its pictures — at tier 0, on this device's own relay, and
/// served from there over Reticulum. The public relay it came from can then rot,
/// go paid or vanish, and nothing the user cared about goes with it.
///
/// ## Where the work runs (docs/performance.md)
///
/// Nothing expensive happens on the UI isolate, and the two rules that keep it
/// that way are not negotiable:
///
/// 1. **Signature verification stays in the `nostr-engine` isolate.** A keep
///    often has to *fetch* a note (and its parents) that this device never held.
///    Those fetches go through the engine — it owns the relays and the
///    secp256k1 — and come back already verified, so the main isolate stores
///    them with [RelayEventStore.putAllVerified] and never runs Schnorr. Calling
///    `put()` here would put secp256k1 back on the UI thread: the exact pattern
///    that once froze the app for hours (§3.1).
/// 2. **Nothing blocks, ever.** [keep] enqueues and returns. A timer drains a
///    few items per tick; the store work per item is a handful of indexed
///    lookups and a primary-key UPDATE. Media is fetched over the network with
///    a size cap and a bounded number in flight.
///
/// The queue is **persisted**, so a keep survives the app being backgrounded or
/// killed mid-flight: the headless engine that already runs the background
/// wapps and RnsService picks the queue up and finishes it. A user who liked
/// something on a train, in a tunnel, still has it when they get home.
class KeepService {
  KeepService._();
  static final KeepService instance = KeepService._();

  /// Per tick: how many pending keeps to advance, and how much media to pull.
  static const int _perTick = 3;
  static const int _maxMediaInFlight = 2;
  static const Duration _tick = Duration(seconds: 3);

  /// A note we asked the relays for and that never came. Bounded, and given up
  /// on — "cache the miss, not just the hit" (docs/performance.md §3.2): on a
  /// public network a note that no relay still holds is the *common* case, and
  /// retrying it forever is how a queue becomes a spin.
  static const int _maxAttempts = 12; // ~36s of asking, then let it go.

  /// How deep a keep may recurse. The thread walk in [planKeep] is already
  /// bounded; this bounds the *fetch* chain it can spawn.
  static const int _maxPending = 200;

  final List<_Keep> _pending = [];
  final Set<String> _mediaInFlight = {};
  final Set<String> _mediaDone = {};
  Timer? _timer;
  bool _loaded = false;

  RnsService get _rns => RnsService.instance;

  /// The user touched [eventId]. Returns immediately; the keeping happens
  /// behind them.
  void keep(Touch touch, String eventId, {String authorHex = ''}) {
    if (eventId.length != 64) return;
    _load();
    if (_pending.any((k) => k.id == eventId)) return;
    if (_pending.length >= _maxPending) return;
    _pending.add(_Keep(id: eventId, touch: touch, author: authorHex));
    _save();
    LogService.instance.add(
        'keep: ${touch.name} ${eventId.substring(0, 8)} (queue ${_pending.length})');
    _arm();
  }

  /// Resume a queue left behind by a previous run (called once RnsService's
  /// store + engine are up — including inside the Android background service,
  /// which is the same Dart isolate as the headless engine).
  void resume() {
    _load();
    if (_pending.isNotEmpty) {
      LogService.instance.add('keep: resuming ${_pending.length} unfinished');
      _arm();
    }
  }

  void _arm() {
    _timer ??= Timer.periodic(_tick, (_) => _drain());
  }

  void _drain() {
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final store = _rns.relayStore;
    final hub = _rns.nostrHub;
    if (store == null || hub == null) return; // not up yet; try next tick

    var worked = 0;
    for (final k in List<_Keep>.from(_pending)) {
      if (worked >= _perTick) break;
      worked++;
      k.attempts++;

      // 1. Do we hold the event? The engine's cache answers instantly when it
      //    has it, and ASKS THE RELAYS when it does not — on its own isolate.
      final json = hub.eventById(k.id);
      if (json == null) {
        if (k.attempts >= _maxAttempts) {
          LogService.instance
              .add('keep: gave up on ${k.id.substring(0, 8)} — no relay has it');
          _pending.remove(k);
          _save();
        }
        continue; // ask again next tick
      }

      NostrEvent ev;
      try {
        ev = NostrEvent.fromJson(json);
      } catch (_) {
        _pending.remove(k);
        _save();
        continue;
      }

      try {
        // 2. Into the store we SERVE, at tier 0. putAllVerified, never put():
        //    the engine isolate already checked the signature, and re-checking
        //    it here would run secp256k1 on the UI isolate.
        store.putAllVerified([ev], tier: 0);

        // 3. What else is this note worth? Its author, its thread, its media.
        final plan = planKeep(
          touch: k.touch,
          targetId: k.id,
          target: ev,
          store: store,
        );
        final pinned = applyKeep(plan, store);

        // The parents we lack become keeps of their own — same machinery, and
        // the queue cap is what stops a crafted thread from being a fetch bomb.
        for (final id in plan.fetchIds) {
          if (_pending.length >= _maxPending) break;
          if (_pending.any((p) => p.id == id)) continue;
          _pending.add(_Keep(id: id, touch: Touch.reply, author: ''));
        }

        // A note whose author is anonymous in ten years is half a memory. The
        // engine fetches the kind-0; the mirror puts it in the served store.
        for (final pub in plan.fetchProfiles) {
          hub.trackProfile(pub);
        }

        // The pictures, from the internet, NOW — while the internet that holds
        // them is still there. That is the whole point of the exercise.
        _keepMedia(plan.fetchMedia, ev.pubkey);

        // Present is not the same as findable. Tell the DHT that this device is
        // a home for this author, so an Indexer asked "where can I find npub X"
        // can answer with us — a pointer, ~176 bytes, no content leaves here.
        unawaited(_rns.publishAuthorProvider(ev.pubkey));

        LogService.instance.add(
            'keep: ${k.touch.name} ${k.id.substring(0, 8)} pinned=$pinned '
            'parents=${plan.fetchIds.length} media=${plan.fetchMedia.length}');
      } catch (e) {
        LogService.instance.add('keep: ${k.id.substring(0, 8)} failed: $e');
      }

      _pending.remove(k);
      _save();
    }
  }

  /// Pull the media a kept note references into the content-addressed archive,
  /// **pinned**: hosted, served over Blossom and Reticulum, and exempt from the
  /// eviction sweep. A note you liked whose picture we quietly deleted under
  /// pressure would be worse than never having offered.
  void _keepMedia(List<String> refs, String authorPub) {
    final prefs = PreferencesService.instanceSync;
    final maxBytes = (prefs?.keepMediaMaxMb ?? 8) * 1024 * 1024;
    if (maxBytes <= 0) return; // the user said: notes only.
    if (!(prefs?.keepMediaOnCellular ?? false) && _rns.onMeteredNetwork) {
      // Deliberate: the note is already safe. The picture waits for WiFi
      // rather than spending somebody's data plan without being asked.
      LogService.instance.add('keep: media deferred (metered)');
      return;
    }
    for (final ref in refs) {
      if (!ref.startsWith('http')) continue; // file: tokens are already local
      if (_mediaDone.contains(ref) || _mediaInFlight.contains(ref)) continue;
      if (_mediaInFlight.length >= _maxMediaInFlight) break;
      unawaited(_fetchMedia(ref, authorPub, maxBytes));
    }
  }

  Future<void> _fetchMedia(String url, String authorPub, int maxBytes) async {
    _mediaInFlight.add(url);
    try {
      // Reticulum first: if a peer already keeps this blob, we take it from
      // them and no server on the internet learns what we are reading. The
      // internet is the fallback, not the default (docs/NOSTR.md, 8d).
      final got = await _rns.fetchMediaPreferMesh(url, maxBytes: maxBytes);
      final bytes = got.bytes;
      if (bytes == null || bytes.isEmpty) return;
      final archive = sharedMediaArchive();
      if (archive == null) return;
      final token = archive.putHosted(
        bytes,
        _extOf(url),
        originPubHex: authorPub,
        tier: 0,
        pin: true,
      );
      _mediaDone.add(url);
      LogService.instance.add(
          'keep: kept media ${bytes.length}B via ${got.source} -> $token');
    } catch (e) {
      LogService.instance.add('keep: media failed ($url): $e');
    } finally {
      _mediaInFlight.remove(url);
    }
  }

  static String _extOf(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot < clean.length - 6) return 'bin';
    return clean.substring(dot + 1).toLowerCase();
  }

  // ── Persistence: a keep must survive the app dying mid-flight ──────────────

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final raw = PreferencesService.instanceSync?.keepQueue ?? '';
    if (raw.isEmpty) return;
    try {
      for (final j in (jsonDecode(raw) as List)) {
        final m = j as Map<String, dynamic>;
        _pending.add(_Keep(
          id: m['id'] as String? ?? '',
          touch: Touch.values.firstWhere(
            (t) => t.name == (m['touch'] as String? ?? 'react'),
            orElse: () => Touch.react,
          ),
          author: m['author'] as String? ?? '',
        ));
      }
      _pending.removeWhere((k) => k.id.length != 64);
    } catch (_) {
      // A corrupt queue is not worth a crash; drop it.
    }
  }

  void _save() {
    PreferencesService.instanceSync?.keepQueue = jsonEncode([
      for (final k in _pending)
        {'id': k.id, 'touch': k.touch.name, 'author': k.author},
    ]);
  }

  int get pendingCount => _pending.length;
}

class _Keep {
  final String id;
  final Touch touch;
  final String author;
  int attempts = 0;
  _Keep({required this.id, required this.touch, required this.author});
}
