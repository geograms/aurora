import 'package:flutter/material.dart';

import 'models/monitored_task.dart';
import 'connections/builtin_connections.dart';
import 'editor/editor_install.dart';
import 'wapp/host_event_bridge.dart';
import 'services/notification_service.dart';
import 'services/preferences_service.dart';
import 'services/log_service.dart';
import 'services/remote_api_service.dart';
import 'profile/profile_service.dart';
import 'profile/storage_paths.dart';
import 'services/task_monitor_service.dart';

import 'launcher/launcher.dart';

/// Entry point. Boots the host services through the [BootOrchestrator]
/// and runs the launcher ([IwiApp]). All launcher UI lives in
/// lib/launcher/.
Future<void> main() async {
  // Required before any async work that touches platform channels.
  WidgetsFlutterBinding.ensureInitialized();

  // Mirror everything the app prints into the in-memory log buffer so the
  // remote-control API can serve it over /api/log.
  final flutterDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) LogService.instance.add(message);
    flutterDebugPrint(message, wrapWidth: wrapWidth);
  };
  // Proof-of-binary marker — verify via /api/status "build" or /api/log.
  LogService.instance.add('Aurora started — build $kAuroraBuildTag');

  // Resolve the writable storage root for this platform before any boot
  // task touches disk (Android/iOS have no $HOME — use the app sandbox).
  await initStorageRoot();

  // Video playback is an optional add-on: no media backend is bundled in
  // the base app, so the media.video capability stays unbacked here. A
  // backend can register itself via MediaCapabilities.registerBackend.

  // Register core host services as parallel boot tasks so they run
  // through the orchestrator (and show up in the tasks wapp with the
  // boot:parallel pill). They are cheap and independent, so parallel
  // is correct — no contention for CPU or memory.
  BootOrchestrator.instance.register(
    id: 'notification-service',
    name: 'Notification service',
    description:
        'Registers the system tray notification backend and subscribes '
        'to host ErrorEvent. In-app display is handled by the '
        'NotificationLayer overlay wrapping the launcher.',
    mode: BootStart.parallel,
    init: () async {
      NotificationService.instance.init();
    },
  );
  BootOrchestrator.instance.register(
    id: 'register-connections',
    name: 'Register connections',
    description:
        'Registers the built-in transports (internet live; LAN, Bluetooth, '
        'LoRa, USB as capability-declaring stubs) into the '
        'ConnectionRegistry so wapps can reason about available connections '
        'and their characteristics.',
    mode: BootStart.parallel,
    init: () async {
      registerBuiltinConnections();
    },
  );
  BootOrchestrator.instance.register(
    id: 'host-event-bridge',
    name: 'Host → wapp event bridge',
    description:
        'Republishes AppStarted/WappLoaded/WappUnloaded/WappCrashed/'
        'ErrorEvent on the wapp event broker as system.* topics.',
    mode: BootStart.parallel,
    init: () async {
      HostEventBridge.instance.install();
    },
  );
  BootOrchestrator.instance.register(
    id: 'migrate-storage-layout',
    name: 'Migrate storage layout',
    description:
        'One-time on-disk renames: profiles/<id>/ -> devices/<id>/, then '
        'per-device apps/ -> wapps/ (installed packages) and old wapps/ '
        '-> data/ (per-wapp settings). No-op once migrated. Must run '
        'before profile-service and the launcher scan.',
    mode: BootStart.sequential,
    init: migrateStorageLayout,
  );
  BootOrchestrator.instance.register(
    id: 'profile-service',
    name: 'Profile service',
    description:
        'Loads profiles.json and the active profile id. Must run '
        'before the launcher scan because storage_paths.dart '
        'resolves apps/ and wapps/ under the active profile folder.',
    mode: BootStart.sequential,
    init: () async {
      await ProfileService.instance.load();
      // Aurora opens straight onto the wapp launcher — no welcome /
      // profile-creation gate. Storage paths still route through an
      // active profile, so on a fresh install we silently mint a
      // default identity. The user can still add / switch / rename
      // profiles later via the launcher's profile switcher.
      if (!ProfileService.instance.hasProfiles) {
        final preview =
            ProfileService.instance.generatePreview(nickname: 'aurora');
        await ProfileService.instance.saveAndActivate(preview);
      }
    },
  );
  BootOrchestrator.instance.register(
    id: 'install-editor',
    name: 'Install wapp editor',
    description:
        'Installs the built-in wapp editor (App Creator) from bundled '
        'assets into its own root storage location, outside the grid-'
        'scanned wapps/ dir. Idempotent (version-guarded). Reachable only '
        'via the per-wapp Edit action, never as a grid tile.',
    mode: BootStart.sequential,
    init: ensureEditorInstalled,
  );
  BootOrchestrator.instance.register(
    id: 'seed-default-wapps',
    name: 'Seed default wapps',
    description:
        'On a brand-new profile, installs the default set (Wapp Store, '
        'Maps, and the system wapps) into the profile so the launcher is '
        'usable. Runs once per profile (guarded by a .seeded marker). '
        'Must run after profile-service so the active profile exists.',
    mode: BootStart.sequential,
    init: ensureProfileSeeded,
  );

  // Run every registered boot task. Sequential boot tasks run first,
  // alone, in registration order; then all parallels run concurrently.
  await BootOrchestrator.instance.runAll();

  runApp(IwiApp(messengerKey: rootMessengerKey));

  // Remote-control API: start after runApp so the root navigator is live
  // (it backs /api/launch). Gated by a setting (default on); see Settings.
  final prefs = await PreferencesService.instance();
  if (prefs.remoteApiEnabled) {
    await RemoteApiService.instance.start(
      port: prefs.remoteApiPort,
      navigatorKey: rootNavigatorKey,
    );
  }
}
