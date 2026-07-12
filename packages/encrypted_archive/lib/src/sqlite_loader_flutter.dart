import 'package:sqlite3/sqlite3.dart';

/// SQLite loader for Flutter targets.
///
/// The host app is responsible for bundling the native SQLite library
/// (aurora depends on a sqlite3 flutter-libs plugin directly), so this
/// loader just opens through package:sqlite3's default resolution. This
/// keeps encrypted_archive a pure Dart package.
class SQLiteLoader {
  SQLiteLoader._();

  /// Open or create a database at [dbPath].
  static Database openDatabase(String dbPath) {
    return sqlite3.open(dbPath);
  }

  /// Open an in-memory database.
  static Database openInMemory() {
    return sqlite3.openInMemory();
  }
}
