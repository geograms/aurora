part of 'launcher.dart';

class IwiApp extends StatefulWidget {
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  const IwiApp({super.key, required this.messengerKey});

  @override
  State<IwiApp> createState() => _IwiAppState();
}

class _IwiAppState extends State<IwiApp> {
  @override
  void initState() {
    super.initState();
    // Rebuild the root whenever the active profile changes so that
    // (a) the welcome-page → launcher handoff flips cleanly on first
    //     profile creation, and
    // (b) profile switches re-route storage paths and trigger a
    //     launcher rescan on the fresh apps/ folder.
    ProfileService.instance.activeProfileNotifier.addListener(_onProfileChanged);
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
      home: hasProfile
          ? const LauncherPage()
          : WelcomePage(
              // saveAndActivate already flips activeProfileNotifier,
              // so the _onProfileChanged setState above will rebuild
              // this widget with hasProfile==true and swap to the
              // launcher. onComplete is a no-op hook for any future
              // analytics / telemetry.
              onComplete: () {},
            ),
    );
  }
}

