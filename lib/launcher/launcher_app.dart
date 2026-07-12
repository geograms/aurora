part of 'launcher.dart';

class IwiApp extends StatefulWidget {
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  const IwiApp({super.key, required this.messengerKey});

  @override
  State<IwiApp> createState() => _IwiAppState();
}

class _IwiAppState extends State<IwiApp> {
  PreferencesService? _prefs;
  bool _gateReady = false;   // prefs + permission status both loaded
  bool _permsGranted = false;
  int _lastJankLogMs = 0;

  @override
  void initState() {
    super.initState();
    // Rebuild the root whenever the active profile changes so that
    // (a) the welcome-page → launcher handoff flips cleanly on first
    //     profile creation, and
    // (b) profile switches re-route storage paths and trigger a
    //     launcher rescan on the fresh apps/ folder.
    ProfileService.instance.activeProfileNotifier.addListener(_onProfileChanged);
    // UI-stall telemetry: log frames that took >100ms (a felt touch hiccup),
    // rate-limited to one line per 5s so a bad stretch can't flood the log.
    // Per-task attribution lives in TaskMonitorService; this catches the total.
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _loadGate();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final ms = t.totalSpan.inMilliseconds;
      if (ms < 100) continue;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastJankLogMs < 5000) return;
      _lastJankLogMs = now;
      LogService.instance.add(
        'perf: frame ${ms}ms (build ${t.buildDuration.inMilliseconds}ms, '
        'raster ${t.rasterDuration.inMilliseconds}ms)',
      );
      return;
    }
  }

  // Load prefs + current permission status, both needed to decide whether the
  // first-run permissions intro is shown.
  Future<void> _loadGate() async {
    final prefs = await PreferencesService.instance();
    final granted = await AndroidPermissionsService.instance.allGranted();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _permsGranted = granted;
      _gateReady = true;
    });
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier
        .removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasProfile = ProfileService.instance.hasProfiles &&
        ProfileService.instance.activeProfile != null;
    return MaterialApp(
      title: 'geogram',
      // Root navigator key — lets context-free services (the remote-control
      // API) push routes, e.g. open a wapp on /api/launch.
      navigatorKey: rootNavigatorKey,
      // Kept for ad-hoc Flutter snackbars (e.g. settings delete errors).
      // The unified NotificationService does NOT use this — it pipes
      // everything through the NotificationLayer overlay below.
      scaffoldMessengerKey: widget.messengerKey,
      debugShowCheckedModeBanner: false,
      // Material 3's default seed is purple; override to blue so
      // the launcher, buttons and accents land on a cooler palette
      // that matches the geogram brand.
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F6CFF),
          brightness: Brightness.dark,
        ),
      ),
      // The NotificationLayer is installed via `builder`, not `home:`,
      // so it sits ABOVE the Navigator. That way its stacking overlay
      // renders on top of whatever route is currently visible — the
      // launcher AND every pushed wapp page. If we wrapped only
      // `home:`, wapp pages (which are siblings of home in the
      // navigator stack) would cover the notification cards.
      builder: (context, child) {
        return NotificationLayer(child: child ?? const SizedBox.shrink());
      },
      home: _home(hasProfile),
    );
  }

  Widget _home(bool hasProfile) {
    final prefs = _prefs;
    if (!_gateReady || prefs == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // First-run Android permissions intro: shown whenever the required
    // permissions are NOT all granted. It gates PURELY on live status (not a
    // stored flag), so a user who denied cannot slip past to profile creation
    // — the intro's Continue button is disabled until everything is granted,
    // which is what keeps any prompt from surfacing later. Already-granted
    // (e.g. reinstall) skips it entirely.
    final needIntro =
        platform.platformName() == 'android' && !_permsGranted;
    if (needIntro) {
      return PermissionsIntroPage(onComplete: () async {
        // Reached only once everything is granted (button was disabled
        // otherwise). Persist the flag and flip the gate so profile
        // creation becomes reachable.
        await prefs.setOnboardingComplete(true);
        final granted = await AndroidPermissionsService.instance.allGranted();
        // NOW start the services that touch permission-guarded APIs (BLE, GPS,
        // foreground-service notifications). Boot deliberately did not, so the
        // OS could not throw its own dialogs at the user before this screen had
        // explained what they are for — nor again after the callsign screen.
        // This intro is the only place a permission prompt comes from.
        unawaited(PermissionGate.startGatedServices());
        if (mounted) setState(() => _permsGranted = granted);
      });
    }
    if (hasProfile) {
      // Seed the active profile's default wapps before the grid renders. The
      // boot task only seeds whatever profile existed at startup; a profile
      // created via WelcomePage (first run) or added via the switcher needs
      // seeding here. ensureProfileSeeded is idempotent (per-profile
      // .seeded.json), so re-running for an already-seeded profile is instant.
      // Keyed by profile id so it re-runs when the active profile changes.
      final pid = ProfileService.instance.activeProfile!.id;
      return FutureBuilder<void>(
        key: ValueKey('seed-$pid'),
        future: ensureProfileSeeded(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return const LauncherPage();
        },
      );
    }
    // saveAndActivate flips activeProfileNotifier, so _onProfileChanged
    // rebuilds with hasProfile==true and swaps to the launcher (via the
    // seed gate above).
    return WelcomePage(onComplete: () {});
  }
}

