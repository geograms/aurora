import 'dart:async';

import 'package:reticulum/src/services/social/relay_role.dart';

import '../log_service.dart';
import '../reticulum/rns_service.dart';
import 'archiver_service.dart';

/// Mirror the small devices around us (docs/NOSTR.md, the Archiver).
///
/// A phone that holds the only copy of a neighbourhood's photos is one drop away
/// from losing them — and every time somebody fetches from it, the phone pays:
/// a radio wakes, a battery drains, and on a metered plan somebody is billed by
/// the megabyte.
///
/// So an Archiver pulls what those devices are willing to share, and then
/// **publishes itself as a provider**. From that moment the DHT hands out the
/// mains-powered box instead of the phone. The data gets redundancy and the
/// phone gets left alone; both halves matter, and the second one is the one
/// people feel.
///
/// Deliberately conservative:
///   - only when the owner actually volunteered storage (an Archiver, with a
///     quota above zero) — silence is not consent;
///   - only when this device is itself always-on;
///   - never on a metered connection, because mirroring is discretionary and
///     spending somebody's data plan on it without being asked would be rude;
///   - one author per tick, so it trickles rather than floods.
class MirrorService {
  MirrorService._();
  static final MirrorService instance = MirrorService._();

  /// Slow on purpose. Mirroring is a background kindness, not a race.
  static const Duration _tick = Duration(minutes: 7);

  /// Authors we have mirrored recently, so a quiet neighbourhood costs nothing.
  static const Duration _again = Duration(hours: 6);
  final Map<String, DateTime> _done = {};

  Timer? _timer;
  int _cursor = 0;

  RnsService get _rns => RnsService.instance;

  void start() {
    _timer ??= Timer.periodic(_tick, (_) => unawaited(_mirrorOne()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _shouldMirror {
    final policy = ArchiverService.instance.policy;
    if (!policy.isArchiving || !policy.mirrorSmallDevices) return false;
    if (!_rns.isIndexer) return false; // a phone does not mirror other phones
    if (_rns.onMeteredNetwork) return false;
    return true;
  }

  /// The battery-powered peers worth taking the weight off: leaves that told us
  /// who they are (their announce carries their pubkey), freshest first.
  List<RelayEntry> _leaves() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = [
      for (final e in _rns.relayDirectory.entries())
        if (!e.announcement.isIndexer &&
            (e.announcement.pubkey?.length ?? 0) == 64 &&
            now - e.lastSeenMs < 24 * 3600 * 1000)
          e
    ]..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return out;
  }

  Future<void> _mirrorOne() async {
    if (!_shouldMirror) return;

    final leaves = _leaves();
    if (leaves.isEmpty) return;

    final now = DateTime.now();
    for (var i = 0; i < leaves.length; i++) {
      final e = leaves[(_cursor + i) % leaves.length];
      final pub = e.announcement.pubkey!.toLowerCase();
      final last = _done[pub];
      if (last != null && now.difference(last) < _again) continue;

      _cursor = (_cursor + i + 1) % leaves.length;
      _done[pub] = now;
      if (_done.length > 500) {
        _done.remove(_done.keys.first); // bounded; a big street is still a street
      }

      // Take what they are willing to share…
      final stored = await _rns.fetchAuthorFromMesh(pub, limit: 100);
      if (stored <= 0) return;

      // …and become the place people are sent to, so the phone stops being woken
      // for it. That is the whole point of the exercise.
      await _rns.publishAuthorProvider(pub);
      LogService.instance.add(
        'archive: mirrored ${stored} note(s) from ${pub.substring(0, 12)} — '
        'the DHT now points here instead of their phone',
      );
      return; // one per tick; it trickles.
    }
  }
}
