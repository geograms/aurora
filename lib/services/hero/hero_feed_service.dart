import 'dart:async';

import 'package:flutter/foundation.dart';

import '../event_bus.dart';
import 'hero_inbox.dart';
import 'hero_item.dart';
import 'hero_ranker.dart';
import 'hero_source.dart';
import 'launcher_visibility.dart';
import 'nostr_hero_source.dart';
import 'welcome_hero_source.dart';
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

  final ValueNotifier<List<HeroItem>> items = ValueNotifier<List<HeroItem>>(
    const [],
  );

  final List<HeroSource> _sources = [NostrHeroSource(), WappHeroSource()];

  /// Fallback-only source (see [refresh]): never mixed with real content.
  final WelcomeHeroSource _welcome = WelcomeHeroSource();

  /// The carousel is showing nothing but the local welcome cards — i.e. no
  /// post has arrived yet, from any relay or the mesh.
  ///
  /// The refresher polls fast until content lands and slowly afterwards, and
  /// it must not mistake OUR OWN placeholder for content: doing so dropped it
  /// straight to the 5-minute cadence on a fresh install, so the first real
  /// post could sit unshown for minutes after the relays had already sent it.
  bool get hasNoRealContent =>
      items.value.every((i) => i.sourceId == kHeroSourceWelcome);

  void register(HeroSource source) {
    if (_sources.any((s) => s.id == source.id)) return;
    _sources.add(source);
  }

  int _serial = 0;
  String _lastSignature = '';
  DateTime? _lastRefresh;

  DateTime? get lastRefresh => _lastRefresh;

  void setVisible(bool visible) {
    for (final source in _sources) {
      if (source is NostrHeroSource) source.setActive(visible);
    }
  }

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
    // Fresh install: nothing has been relayed to us yet, and an empty carousel
    // for the first minutes of a new app is what makes it look broken. The
    // welcome cards fill it locally and step aside the moment a real item
    // arrives — they are only asked for when every other source came back with
    // nothing.
    if (gathered.isEmpty) {
      try {
        gathered.addAll(await _welcome.candidates());
      } catch (_) {
        // keep the empty-state card
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
  static const Duration _every = Duration(minutes: 10);

  /// …but an EMPTY hero is a different situation. On a cold start the relays are
  /// still answering, and making the user wait out a five-minute tick to see the
  /// first post is the difference between an app that works and one that looks
  /// broken. Check back quickly until there is something on screen, then settle.
  /// This costs nothing on the network — it re-reads a buffer the hub has
  /// already filled.
  static const Duration _whileEmpty = Duration(seconds: 20);

  /// On becoming visible, refresh at once if what's on screen is older than
  /// this. Without it, returning to the launcher after an hour would show a
  /// stale hero for up to five more minutes.
  static const Duration _staleAfter = Duration(seconds: 90);

  Timer? _timer;
  EventSubscription<AppStartedEvent>? _appStarted;
  StreamSubscription<void>? _followChanges;
  int _inboxRevision = 0;

  void start() {
    _onVisibility(); // the launcher is on screen right now — fill it
    LauncherVisibility.instance.visible.addListener(_onVisibility);
    _appStarted = EventBus().on<AppStartedEvent>((_) => _safeRefresh());
    _followChanges = RnsService.instance.followChanges.listen((_) {
      if (LauncherVisibility.instance.visible.value) _safeRefresh();
    });
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
    _followChanges?.cancel();
  }

  void _onInbox() {
    if (HeroInbox.instance.revision.value == _inboxRevision) return;
    _inboxRevision = HeroInbox.instance.revision.value;
    if (LauncherVisibility.instance.visible.value) _safeRefresh();
  }

  void _onVisibility() {
    HeroFeedService.instance.setVisible(
      LauncherVisibility.instance.visible.value,
    );
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
    _arm();
  }

  /// Fast while the hero has nothing to show, slow once it does.
  bool _fast = true;

  void _arm() {
    _fast = HeroFeedService.instance.hasNoRealContent;
    _timer?.cancel();
    _timer = Timer.periodic(
      _fast ? _whileEmpty : _every,
      (_) => _safeRefresh(),
    );
  }

  void _safeRefresh() {
    unawaited(
      refresh()
          .then((_) {
            // The moment the first post lands, drop back to the slow cadence — the
            // fast one exists only to get something on screen, not to keep polling.
            if (!LauncherVisibility.instance.visible.value) return;
            if (_fast != HeroFeedService.instance.hasNoRealContent) _arm();
          })
          .catchError((_) {}),
    );
  }
}
