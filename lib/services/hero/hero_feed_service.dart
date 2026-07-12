import 'dart:async';

import 'package:flutter/foundation.dart';

import '../event_bus.dart';
import 'hero_inbox.dart';
import 'hero_item.dart';
import 'hero_ranker.dart';
import 'hero_source.dart';
import 'launcher_visibility.dart';
import 'nostr_hero_source.dart';
import '../reticulum/rns_service.dart';

/// The launcher's hero carousel, as a feed anything can publish into.
///
/// Two sources ship: NOSTR (built in — see [NostrHeroSource] for why it isn't a
/// wapp) and whatever wapps have published through `hero.publish`. Adding a
/// third means implementing [HeroSource] and calling [register]; the ranker's
/// caps mean a new source cannot elbow the others out.
class HeroFeedService {
  HeroFeedService._();
  static final HeroFeedService instance = HeroFeedService._();

  final ValueNotifier<List<HeroItem>> items =
      ValueNotifier<List<HeroItem>>(const []);

  final List<HeroSource> _sources = [NostrHeroSource(), WappHeroSource()];

  void register(HeroSource source) {
    if (_sources.any((s) => s.id == source.id)) return;
    _sources.add(source);
  }

  int _serial = 0;
  String _lastSignature = '';
  DateTime? _lastRefresh;

  DateTime? get lastRefresh => _lastRefresh;

  Future<void> refresh({int limit = 10}) async {
    final serial = ++_serial;

    final gathered = <HeroItem>[];
    for (final s in _sources) {
      try {
        gathered.addAll(await s.candidates());
      } catch (_) {
        // A broken source must not blank the hero.
      }
    }
    if (serial != _serial) return; // a newer refresh already won

    final ranked = rankHero(
      gathered,
      follows: RnsService.instance.follows.asSet,
      limit: limit,
      now: DateTime.now(),
    );
    _lastRefresh = DateTime.now();

    // Skip the notifier when nothing actually changed: the carousel is a
    // PageView and rebuilding it mid-swipe for an unchanged like count would
    // yank the card out from under the user's thumb.
    final signature = [for (final i in ranked) i.signature].join('|');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    items.value = List<HeroItem>.of(ranked);
  }
}

/// Drives [HeroFeedService.refresh] — but only while someone is looking.
///
/// The old refresher ran `Timer.periodic(1 minute)` unconditionally, so it kept
/// draining, parsing and re-ranking behind wapp pages and with the screen off.
/// This one holds no timer at all while the launcher is hidden.
class HeroRefresher {
  HeroRefresher(this.refresh);
  final Future<void> Function() refresh;

  /// A poll interval is a battery setting, not a freshness setting
  /// (docs/performance.md §6.5). The relays PUSH into the hub; this only governs
  /// how often we go back to the buffer it has already filled.
  static const Duration _every = Duration(minutes: 5);

  /// On becoming visible, refresh at once if what's on screen is older than
  /// this. Without it, returning to the launcher after an hour would show a
  /// stale hero for up to five more minutes.
  static const Duration _staleAfter = Duration(seconds: 90);

  Timer? _timer;
  EventSubscription<AppStartedEvent>? _appStarted;
  int _inboxRevision = 0;

  void start() {
    _onVisibility(); // the launcher is on screen right now — fill it
    LauncherVisibility.instance.visible.addListener(_onVisibility);
    _appStarted = EventBus().on<AppStartedEvent>((_) => _safeRefresh());
    // A wapp can publish while headless; when it does, don't make the user wait
    // out the rest of the 5-minute tick to see the card.
    _inboxRevision = HeroInbox.instance.revision.value;
    HeroInbox.instance.revision.addListener(_onInbox);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    LauncherVisibility.instance.visible.removeListener(_onVisibility);
    HeroInbox.instance.revision.removeListener(_onInbox);
    _appStarted?.cancel();
  }

  void _onInbox() {
    if (HeroInbox.instance.revision.value == _inboxRevision) return;
    _inboxRevision = HeroInbox.instance.revision.value;
    if (LauncherVisibility.instance.visible.value) _safeRefresh();
  }

  void _onVisibility() {
    if (!LauncherVisibility.instance.visible.value) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return; // already running
    final last = HeroFeedService.instance.lastRefresh;
    if (last == null || DateTime.now().difference(last) > _staleAfter) {
      _safeRefresh();
    }
    _timer = Timer.periodic(_every, (_) => _safeRefresh());
  }

  void _safeRefresh() {
    unawaited(refresh().catchError((_) {}));
  }
}
