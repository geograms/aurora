/*
 * Aurora launcher library.
 *
 * All launcher-facing source lives here, split into `part` files so the
 * many private widgets stay library-private while each concern sits in
 * its own file:
 *   - wapp_manifest.dart    — the WappManifest model
 *   - seeding.dart          — first-run default-wapp install
 *   - launcher_app.dart     — IwiApp root MaterialApp
 *   - launcher_page.dart    — the launcher grid + profile switcher
 *   - settings_page.dart    — the Settings screen
 *   - wapp_runner_page.dart — generic WASM runner page
 *
 * `lib/main.dart` is just the entry point: it boots services and runs
 * [IwiApp] from this library.
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../platform/platform.dart' as platform;

import '../models/wapp_file_handler.dart';
import '../profile/welcome_page.dart';
import '../services/event_bus.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../profile/profile_service.dart';
import '../profile/profile_storage.dart';
import '../profile/profile_storage_factory.dart';
import '../services/dependency_resolver.dart';
import '../profile/storage_paths.dart';
import '../services/task_monitor_service.dart';
import '../services/wapp_installer_service.dart';
import '../services/wapp_signing_service.dart';
import '../services/functionality_registry.dart';
import '../util/wapp_icons.dart';
import '../wapp/wapp_engine.dart';
import '../wapp/wapp_page.dart';

part 'wapp_manifest.dart';
part 'seeding.dart';
part 'launcher_app.dart';
part 'launcher_page.dart';
part 'settings_page.dart';
part 'wapp_runner_page.dart';

/// Global messenger key. Held outside any widget so the
/// [NotificationService] can drive snackbars without needing a
/// BuildContext from inside an event handler.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
