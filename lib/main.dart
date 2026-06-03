import 'package:flutter/material.dart';

import 'platform/platform.dart' as platform;

import 'models/monitored_task.dart';
import 'services/host_event_bridge.dart';
import 'services/notification_service.dart';
import 'services/profile_service.dart';
import 'services/task_monitor_service.dart';
import 'wapp/native/media_kit_video_backend.dart';

import 'launcher/launcher.dart';

/// Entry point. Boots the host services through the [BootOrchestrator]
/// and runs the launcher ([IwiApp]). All launcher UI lives in
/// lib/launcher/.
Future<void> main() async {
  // Required before any async work that touches platform channels.
  WidgetsFlutterBinding.ensureInitialized();

  // Register the platform media backend behind the `media.video`
  // capability (the mediapack library wapp). No-op on unsupported
  // platforms. media_kit lives entirely inside this backend module —
  // the launcher and wapp runtime never import it directly.
  registerMediaKitBackend(platform.platformName());

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
}
