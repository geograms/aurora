// Shared helper for headless `dart run` tool tests that need SQLite.
//
// The `sqlite3` Dart package loads `libsqlite3.so` from the default loader path.
// Dev boxes and CI sometimes only have the versioned `libsqlite3.so.0` (or only
// inside snap/flatpak runtimes). This probes a list of candidates and, if the
// default load fails, overrides the package to use the first one that opens.
// The Flutter app is unaffected — it bundles the lib via sqlite3_flutter_libs.
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _done = false;

/// Make `sqlite3` loadable in a headless process. Idempotent. Throws only if no
/// libsqlite3 can be found anywhere on the system.
void ensureSqlite() {
  if (_done) return;
  _done = true;

  // 1) Default name already on the loader path? Then nothing to do.
  for (final name in ['libsqlite3.so', 'libsqlite3.so.0']) {
    try {
      final lib = DynamicLibrary.open(name);
      open.overrideForAll(() => lib);
      return;
    } catch (_) {/* try next */}
  }

  // 2) Search common locations (incl. snap/flatpak runtimes) for a .so.0.
  final dirs = <String>[
    '/usr/lib/x86_64-linux-gnu',
    '/usr/lib',
    '/lib/x86_64-linux-gnu',
    '/usr/local/lib',
  ];
  final candidates = <String>[];
  for (final d in dirs) {
    candidates.add('$d/libsqlite3.so.0');
    candidates.add('$d/libsqlite3.so');
  }
  // Snap/flatpak fallbacks (revisions vary — glob the newest).
  for (final root in ['/snap', '/var/lib/flatpak/runtime']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    try {
      for (final f in dir.listSync(recursive: true, followLinks: false)) {
        if (f is File && f.path.endsWith('libsqlite3.so.0')) {
          candidates.add(f.path);
        }
      }
    } catch (_) {/* permission denied on some subtrees — ignore */}
  }

  for (final path in candidates) {
    if (!File(path).existsSync()) continue;
    try {
      final lib = DynamicLibrary.open(path);
      open.overrideForAll(() => lib);
      return;
    } catch (_) {/* try next */}
  }

  throw StateError(
      'libsqlite3 not found. Install it (e.g. apt-get install -y libsqlite3-0) '
      'or run the assertions under `flutter test` (sqlite3_flutter_libs).');
}
