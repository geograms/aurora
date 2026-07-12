import 'package:flutter/material.dart';

import '../log_service.dart';

/// Is the user actually looking at the launcher right now?
///
/// This did not exist before, and its absence was a battery bug: `LauncherPage`
/// stays mounted underneath every pushed wapp route, so its timers — the hero
/// refresh, the carousel's auto-advance, the connection dot's poll — kept firing
/// while a wapp was on top and while the screen was off. Nothing in the app
/// observed routes or lifecycle. docs/performance.md §6.3 lists exactly this as
/// a cheap win not yet taken; [visible] is what takes it.
///
/// Visible means BOTH:
///  * the launcher is the top route (no wapp page pushed over it), and
///  * the app is resumed (not backgrounded, screen not off).
///
/// `rootNavigatorKey.canPop()` is not a substitute: the all-apps sheet and the
/// drawer don't push routes (so it would say "hidden" when the launcher is very
/// much on screen), and a dialog would false-negative the same way.
class LauncherVisibility with WidgetsBindingObserver {
  LauncherVisibility._();
  static final LauncherVisibility instance = LauncherVisibility._();

  final ValueNotifier<bool> visible = ValueNotifier<bool>(false);

  bool _routeOnTop = false;
  bool _resumed = true;
  bool _bound = false;

  void bind() {
    if (_bound) return;
    _bound = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void setRouteOnTop(bool v) {
    if (_routeOnTop == v) return;
    _routeOnTop = v;
    _recompute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_resumed == resumed) return;
    _resumed = resumed;
    _recompute();
  }

  void _recompute() {
    final next = _routeOnTop && _resumed;
    if (visible.value == next) return;
    visible.value = next;
    // The hero's timers hang off this, so when the carousel looks stale (or a
    // phone is burning battery on a launcher nobody can see) this line is the
    // first thing to check.
    LogService.instance.add(
      'hero: launcher ${next ? 'visible' : 'hidden'} '
      '(route=$_routeOnTop resumed=$_resumed)',
    );
  }
}

/// Registered on `MaterialApp.navigatorObservers`; `LauncherPage` subscribes to
/// it as a `RouteAware` so it learns when a wapp page covers or uncovers it.
final RouteObserver<ModalRoute<void>> launcherRouteObserver =
    RouteObserver<ModalRoute<void>>();
