import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

/// SQLite loader for pure Dart/CLI contexts.
///
/// Tries to load a bundled SQLite dynamic library so we can run fully offline.
/// If no bundled library is found, falls back to the system loader.
class SQLiteLoader {
  SQLiteLoader._();

  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized) return;
    var libPath = _resolveLibPath();
    // Fall back to the versioned soname: distros ship libsqlite3.so.0 but the
    // unversioned .so symlink only comes with the -dev package, and
    // package:sqlite3's default loader asks for 'libsqlite3.so'.
    if (libPath == null && Platform.isLinux) {
      libPath = 'libsqlite3.so.0';
    }
    if (libPath != null) {
      final resolved = libPath;
      final loader = () => DynamicLibrary.open(resolved);
      switch (Platform.operatingSystem) {
        case 'linux':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, loader);
          break;
        case 'macos':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.macOS, loader);
          break;
        case 'windows':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.windows, loader);
          break;
      }
    }
    _initialized = true;
  }

  static Database openDatabase(String dbPath) {
    _ensureInitialized();
    return sqlite3.open(dbPath);
  }

  static Database openInMemory() {
    _ensureInitialized();
    return sqlite3.openInMemory();
  }

  static String? _resolveLibPath() {
    // Allow explicit override.
    final override = Platform.environment['SQLITE_DYLIB_PATH'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }

    final candidates = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final scriptDir = _scriptDirectory();
    final cwd = Directory.current.path;

    final name = _platformLibName();
    if (name == null) return null;

    final platformDir = _platformDir();

    void addPaths(String base) {
      if (platformDir != null) {
        candidates.add(p.join(base, 'third_party', 'sqlite', platformDir, name));
      }
      candidates.add(p.join(base, 'libs', name));
      candidates.add(p.join(base, name));
    }

    addPaths(cwd);
    if (scriptDir != null) addPaths(scriptDir);
    addPaths(exeDir);

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static String? _platformLibName() {
    switch (Platform.operatingSystem) {
      case 'linux':
        return 'libsqlite3.so.0';
      case 'macos':
        return 'libsqlite3.dylib';
      case 'windows':
        return 'sqlite3.dll';
      default:
        return null;
    }
  }

  static String? _platformDir() {
    final os = Platform.operatingSystem;
    final arch = Platform.version.contains('x64') || Platform.version.contains('x86_64')
        ? 'x64'
        : (Platform.version.contains('arm64') ? 'arm64' : null);
    if (arch == null) return null;
    switch (os) {
      case 'linux':
        return 'linux-$arch';
      case 'macos':
        return 'macos-$arch';
      case 'windows':
        return 'windows-$arch';
      default:
        return null;
    }
  }

  static String? _scriptDirectory() {
    try {
      final uri = Platform.script;
      if (uri.scheme == 'file') {
        return File.fromUri(uri).parent.path;
      }
    } catch (_) {
      // ignore
    }
    return null;
  }
}
