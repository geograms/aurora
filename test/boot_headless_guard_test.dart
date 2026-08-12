/*
 * The boot engine has no Activity, and that is a trap you cannot feel from a
 * test host.
 *
 * Android starts Aurora at BOOT_COMPLETED with a bare FlutterEngine — no
 * Activity, therefore no PlatformPlugin, therefore no handler on the
 * `flutter/platform` channel. Anything awaited on that channel throws
 * MissingPluginException. main() awaited SystemChrome.setPreferredOrientations
 * as its second statement, so on every reboot main() died there: no splash, no
 * log line, no services, nothing on the air. MainActivity then reused that
 * rootless engine and the user got a black screen that survived every reopen.
 *
 * Nothing at runtime catches this on Linux or in flutter_test, because both
 * have a view and a real platform handler. So the invariant is checked where it
 * is visible: in the source of main().
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Compile-time proof that both platform implementations carry the API. If
// either drops a symbol, this file stops compiling.
import 'package:aurora/platform/platform.dart'
    show hasImplicitView, signalDartReady;

void main() {
  final source = File('lib/main.dart').readAsStringSync();

  test('the orientation lock is skipped when there is no view', () {
    expect(source, contains('setPreferredOrientations'),
        reason: 'guarding the wrong file');

    final guard = source.indexOf('if (hasImplicitView)');
    final call = source.indexOf('setPreferredOrientations');
    expect(guard, greaterThan(-1),
        reason: 'a UI-only platform channel must be gated on having a view — '
            'the boot engine has none and the call throws');
    expect(guard, lessThan(call),
        reason: 'the guard has to come before the call it protects');
  });

  test('nothing UNGUARDED is awaited on flutter/platform before runApp', () {
    final firstRunApp = source.indexOf('runApp(');
    expect(firstRunApp, greaterThan(-1));

    // Everything up to the view guard runs on the boot engine unconditionally.
    final guard = source.indexOf('if (hasImplicitView)');
    final unguarded = source.substring(0, guard < 0 ? firstRunApp : guard);

    // SystemChrome/SystemNavigator are the UI-only families on that channel.
    for (final line in unguarded.split('\n')) {
      final code = line.trim();
      if (!code.startsWith('await ')) continue;
      expect(code.contains('SystemChrome.'), isFalse,
          reason: 'reached with no view and no handler, so it throws: $code');
      expect(code.contains('SystemNavigator.'), isFalse,
          reason: 'reached with no view and no handler, so it throws: $code');
    }
  });

  test('Dart tells the host as soon as it owns a root widget', () {
    final firstRunApp = source.indexOf('runApp(');
    final ready = source.indexOf('signalDartReady()');
    expect(ready, greaterThan(firstRunApp),
        reason: 'readiness means "a view attached here would draw", which is '
            'only true once runApp has run');
  });

  test('a boot failure is written down instead of vanishing', () {
    expect(source, contains('runZonedGuarded'),
        reason: 'a throw on the way up left no trace at all — no widget to '
            'show it, no log line, and /api/log never starts');
    expect(source, contains('BOOT FAILED'));
  });

  test('the host refuses to hand the UI an engine that never came up', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/example/iwi/MainActivity.kt',
    ).readAsStringSync();
    final provide = kotlin.indexOf('override fun provideFlutterEngine');
    expect(provide, greaterThan(-1));

    final body = kotlin.substring(provide, provide + 600);
    expect(body, contains('discardDeadEngine()'),
        reason: 'reusing a rootless cached engine is what made the black '
            'screen permanent — only force-stop cleared it');
  });

  test('readiness is reset when a new headless engine is created', () {
    final app = File(
      'android/app/src/main/kotlin/com/example/iwi/AuroraApplication.kt',
    ).readAsStringSync();
    expect(app, contains('dartReady = false'),
        reason: 'a stale true from a previous engine would wave the dead one '
            'straight through');

    final bridge = File(
      'android/app/src/main/kotlin/com/example/iwi/BgBridge.kt',
    ).readAsStringSync();
    expect(bridge, contains('"dartReady"'),
        reason: 'the flag needs the channel handler Dart calls');
  });

  test('both platform implementations expose the boot API', () {
    // Referenced so the import is not tree-shaken out of the test.
    expect(signalDartReady, isNotNull);
    expect(() => hasImplicitView, returnsNormally);
  });
}
