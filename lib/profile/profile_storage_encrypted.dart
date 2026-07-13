/*
 * Encrypted profile storage backend (Phase 3 of
 * docs/plan-encrypted-storage.md).
 *
 * Routes a profile's file tree between two stores:
 *
 *   - profile.ear (encrypted_archive, AES-256-GCM): every loose user file —
 *     data/<wapp>/kv.json, hal_file_* files, avatar.png, chat JSON, …
 *   - filesystem passthrough: things that MUST be real files —
 *       * wapp packages (`wapps/…`, public software, scope decision)
 *       * every SQLite database (`*.sqlite3*`) — encrypted by SQLCipher
 *         via openProfileDb, live handles can't run inside an archive
 *       * RNS runtime files bound by absolute path from RnsService
 *         (identity key + folder keystore are individually encrypted via
 *         SecureProfileFile; see _passthroughFiles)
 *       * the keyslot / seed markers / the archive itself
 *
 * The archive opens lazily with the ear password derived from the profile
 * master key (ProfileKeyring), and is closed when the profile locks.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypted_archive/encrypted_archive.dart';

import 'profile_db.dart';
import 'profile_storage.dart';
import 'profile_storage_io.dart';

/// Name of the per-profile encrypted archive file.
const String profileArchiveName = 'profile.ear';

class EncryptedProfileStorage extends ProfileStorage {
  final String profileId;
  final String _basePath; // absolute devices/<id>, no trailing slash
  final FilesystemProfileStorage _fs;

  EncryptedProfileStorage(this.profileId, String basePath)
      : _basePath = _stripTrailingSlash(basePath),
        _fs = FilesystemProfileStorage(basePath) {
    _registerLockHook();
  }

  static String _stripTrailingSlash(String p) {
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  // ── shared archive connections ─────────────────────────────────────────

  static final Map<String, EncryptedArchive> _archives = {};

  /// In-flight opens, so the unlock pre-open hook and the first storage op
  /// can't both create/open the same archive concurrently.
  static final Map<String, Future<EncryptedArchive>> _opening = {};
  static bool _hookRegistered = false;

  static void _registerLockHook() {
    if (_hookRegistered) return;
    _hookRegistered = true;
    ProfileKeyring.instance.onLock.add(closeArchive);
    // Pre-open the archive on unlock so sync (WASM HAL) callers find it
    // ready — they cannot await the async open themselves.
    ProfileKeyring.instance.onUnlock.add((profileId) async {
      try {
        final root = '${profileStorageRoot()}/devices/$profileId';
        await EncryptedProfileStorage(profileId, root)._archive();
      } catch (_) {
        // locked again / missing keyslot — sync callers will surface it
      }
    });
  }

  /// Close (and drop) the cached archive connection for [profileId].
  /// Called automatically when the keyring locks a profile.
  static Future<void> closeArchive(String profileId) async {
    final archive = _archives.remove(profileId);
    if (archive != null && !archive.isClosed) {
      await archive.close();
    }
  }

  static Future<void> closeAllArchives() async {
    for (final id in _archives.keys.toList()) {
      await closeArchive(id);
    }
  }

  Future<EncryptedArchive> _archive() {
    final cached = _archives[profileId];
    if (cached != null && !cached.isClosed) return Future.value(cached);
    _archives.remove(profileId);
    // NOTE: the callback must not RETURN the removed future — whenComplete
    // awaits future-returning callbacks and the future would wait on itself.
    return _opening[profileId] ??= _openArchive().whenComplete(() {
      _opening.remove(profileId);
    });
  }

  Future<EncryptedArchive> _openArchive() async {
    final cached = _archives[profileId];
    if (cached != null && !cached.isClosed) return cached;

    final keys = ProfileKeyring.instance.keysFor(profileId);
    if (keys == null) {
      throw ProfileLockedException(profileId, _basePath);
    }
    final path = '$_basePath/$profileArchiveName';
    final earPassword = keys.earPassword;
    ensureSqlCipherLoaded();
    // The ear password is HKDF output of the profile master key — 256 bits
    // of entropy — so heavy Argon2 stretching buys nothing here and would
    // slow every unlock. Cheap parameters, stored in the archive header.
    const options = ArchiveOptions(
      argon2TimeCost: 1,
      argon2MemoryCost: 8192, // 8 MiB
      argon2Parallelism: 1,
    );
    final archive = await _fileExists(path)
        ? await EncryptedArchive.open(path, earPassword)
        : await EncryptedArchive.create(path, earPassword, options: options);
    _archives[profileId] = archive;
    return archive;
  }

  // ── absolute-path bridge (WASM HAL etc.) ───────────────────────────────

  /// For code that only has an absolute path: returns the encrypted storage
  /// + profile-relative path when [absPath] falls inside an encrypted
  /// profile AND is archive-routed. Null → caller should use dart:io.
  static ({EncryptedProfileStorage storage, String rel})? routeAbsolutePath(
      String absPath) {
    final loc = locateProfileDb(absPath);
    if (loc == null) return null;
    if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
    if (isPassthroughPath(loc.relPath)) return null;
    final root = '${profileStorageRoot()}/devices/${loc.profileId}';
    return (
      storage: EncryptedProfileStorage(loc.profileId, root),
      rel: loc.relPath,
    );
  }

  /// Sync access requires the archive to already be open (the async path
  /// opens it at unlock / first use). Throws [StateError] when not.
  EncryptedArchive _archiveSync() {
    final cached = _archives[profileId];
    if (cached != null && !cached.isClosed) return cached;
    if (ProfileKeyring.instance.keysFor(profileId) == null) {
      throw ProfileLockedException(profileId, _basePath);
    }
    throw StateError(
        'profile.ear not open yet — an async storage op must run first');
  }

  Future<bool> _fileExists(String absPath) => _fs.exists(
      absPath.startsWith('$_basePath/')
          ? absPath.substring(_basePath.length + 1)
          : absPath);

  // ── routing ────────────────────────────────────────────────────────────

  /// Files that RnsService & friends bind by ABSOLUTE path and read/write
  /// with dart:io — they must stay real files. The secrets among them
  /// (rns_identity.key, folders.json) are individually encrypted via
  /// SecureProfileFile. If you add a new absolute-path file to
  /// rns_autostart, add it here too, or it will land in the archive and
  /// dart:io access will break for encrypted profiles.
  static const Set<String> _passthroughFiles = {
    'data/rns_identity.key',
    'data/folders.json',
    'data/call_peers.json',
    'data/disk_folders.json',
    'data/folder_subscriptions.json',
    'data/host_follows.json',
    'data/hero_inbox.json',
    'data/hero_media.json',
  };

  static const List<String> _passthroughPrefixes = [
    'wapps/', // wapp packages (public software) + their SQLCipher DBs
    'data/partials/', // resumable-download chunks, dart:io dir scans
    'data/mesh/', // mesh bulk custody chunks (dart:io, MeshService)
    'data/share/', // MediaFileSource share dir (dart:io, reticulum)
  ];

  static bool isPassthroughPath(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (p.isEmpty) return false;
    if (p == keyslotFileName || p == profileArchiveName) return true;
    if (p.startsWith('$profileArchiveName-')) return true; // -wal / -shm
    if (p.startsWith('.seeded')) return true;
    if (p.contains('.sqlite3')) return true; // DBs + -wal/-shm/-journal
    if (_passthroughFiles.contains(p)) return true;
    for (final prefix in _passthroughPrefixes) {
      if (p.startsWith(prefix) || p == prefix.substring(0, prefix.length - 1)) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeRel(String relativePath) {
    var p = relativePath.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.replaceAll(RegExp(r'/+'), '/');
  }

  // ── ProfileStorage interface ───────────────────────────────────────────

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => true;

  @override
  String getAbsolutePath(String relativePath) =>
      _fs.getAbsolutePath(relativePath);

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.readBytes(p);
    final archive = await _archive();
    if (!await archive.exists(p)) return null;
    try {
      return await archive.readFileBytes(p);
    } on EntryNotFoundException {
      return null;
    }
  }

  @override
  Future<void> writeString(String relativePath, String content) =>
      writeBytes(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.writeBytes(p, bytes);
    final archive = await _archive();
    if (await archive.exists(p)) {
      await archive.delete(p);
    }
    await archive.addBytes(p, bytes);
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.appendString(p, content);
    final existing = await readBytes(p);
    final add = Uint8List.fromList(utf8.encode(content));
    if (existing == null) {
      return writeBytes(p, add);
    }
    final merged = Uint8List(existing.length + add.length)
      ..setRange(0, existing.length, existing)
      ..setRange(existing.length, existing.length + add.length, add);
    return writeBytes(p, merged);
  }

  @override
  Future<bool> exists(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.exists(p);
    final archive = await _archive();
    if (!await archive.exists(p)) return false;
    final entry = await archive.getEntry(p);
    return entry.isFile;
  }

  @override
  Future<void> delete(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.delete(p);
    final archive = await _archive();
    try {
      await archive.delete(p);
    } on EntryNotFoundException {
      // match fs backend: deleting a missing file is a no-op
    }
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyFromExternal(externalPath, p);
    final archive = await _archive();
    if (await archive.exists(p)) {
      await archive.delete(p);
    }
    await archive.addFileFromDisk(p, externalPath);
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyToExternal(p, externalPath);
    final archive = await _archive();
    await archive.extractFile(p, externalPath);
  }

  // ── directory ops ──────────────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);

    // Merge: filesystem side (wapps/, sqlite files, markers) + archive side.
    final out = <String, StorageEntry>{};

    if (await _fs.directoryExists(p)) {
      for (final e in await _fs.listDirectory(p, recursive: recursive)) {
        // Hide the archive container + keyslot from listings of the root.
        if (e.path == profileArchiveName ||
            e.path.startsWith('$profileArchiveName-') ||
            e.path == keyslotFileName) {
          continue;
        }
        out[e.path] = e;
      }
    }

    final archive = await _archive();
    final prefix = p.isEmpty ? '' : '$p/';
    final entries = await archive.listFiles(prefix: prefix.isEmpty ? null : prefix);
    final seenDirs = <String>{};
    for (final e in entries) {
      final tail = prefix.isEmpty ? e.path : e.path.substring(prefix.length);
      if (tail.isEmpty) continue;
      if (!recursive && tail.contains('/')) {
        final dirName = tail.substring(0, tail.indexOf('/'));
        if (seenDirs.add(dirName)) {
          final dirPath = prefix + dirName;
          out.putIfAbsent(
              dirPath,
              () => StorageEntry(
                  name: dirName, path: dirPath, isDirectory: true));
        }
        continue;
      }
      if (e.isDirectory) {
        out.putIfAbsent(e.path,
            () => StorageEntry(name: e.name, path: e.path, isDirectory: true));
      } else if (e.isFile) {
        out[e.path] = StorageEntry(
          name: e.name,
          path: e.path,
          isDirectory: false,
          size: e.size,
          modified: e.modifiedAt,
        );
      }
    }
    return out.values.toList();
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.createDirectory(p);
    // Real directory too: sqlite files / passthrough children of this
    // directory need it to exist on disk.
    await _fs.createDirectory(p);
    final archive = await _archive();
    await archive.addDirectory(p);
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) return true;
    if (isPassthroughPath(p)) return false;
    final archive = await _archive();
    if (await archive.exists(p)) {
      final entry = await archive.getEntry(p);
      if (entry.isDirectory) return true;
    }
    final children = await archive.listFiles(prefix: '$p/');
    return children.isNotEmpty;
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) {
      await _fs.deleteDirectory(p, recursive: recursive);
    }
    if (isPassthroughPath(p)) return;
    final archive = await _archive();
    if (recursive) {
      for (final e in await archive.listFiles(prefix: '$p/')) {
        try {
          await archive.delete(e.path);
        } on EntryNotFoundException {
          // already gone
        }
      }
    }
    try {
      await archive.delete(p);
    } on EntryNotFoundException {
      // directory entry may never have been created explicitly
    }
  }

  @override
  Future<void> renameDirectory(String fromRelative, String toRelative) async {
    final from = _normalizeRel(fromRelative);
    final to = _normalizeRel(toRelative);
    if (from.isEmpty || to.isEmpty || from == to) return;
    if (await directoryExists(to)) return;

    if (await _fs.directoryExists(from)) {
      await _fs.renameDirectory(from, to);
    }
    if (isPassthroughPath(from)) return;

    final archive = await _archive();
    for (final e in await archive.listFiles(prefix: '$from/')) {
      final tail = e.path.substring(from.length + 1);
      await archive.rename(e.path, '$to/$tail');
    }
    if (await archive.exists(from)) {
      await archive.rename(from, to);
    }
  }

  // ── sync variants (WASM HAL) ───────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.readBytesSync(p);
    final archive = _archiveSync();
    if (!archive.existsSync(p)) return null;
    try {
      return archive.readFileBytesSync(p);
    } on EntryNotFoundException {
      return null;
    }
  }

  @override
  void writeStringSync(String relativePath, String content) =>
      writeBytesSync(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) {
      _fs.writeBytesSync(p, bytes);
      return;
    }
    _archiveSync().writeBytesSync(p, bytes);
  }

  @override
  bool existsSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.existsSync(p);
    return _archiveSync().existsSync(p);
  }
}
