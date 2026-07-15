/*
 * DiskFolderManager — owner side of disk-backed folders. Registers a real
 * directory as a folder whose master key lives in a hidden file INSIDE the
 * directory, indexes its files by sha256 (served straight from disk, never
 * copied into the archive), and synchronizes changes to the network: it diffs
 * the directory against the folder's currently-published state and emits signed
 * add/remove ops, then advertises a DHT provider for the folder and for every
 * file's sha so consumers can fetch the bytes from this node.
 *
 * Transport-agnostic via injected callbacks so it is unit-testable. Reuses
 * FolderService (owner signing + ops), the folder reducer (for the diff), and
 * the file DHT provider layer.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../util/nostr_crypto.dart';
import 'disk_folder.dart';
import 'folder_keystore.dart';
import 'folder_meta.dart';
import 'folder_event.dart' show pieceSizeForFile, FileEntry;
import 'folder_service.dart';
import 'folder_state.dart';
import 'piece_hashes.dart';

class DiskFolderManager {
  final FolderService folders;
  final Future<FolderState> Function(String folderId) localState;
  final Future<void> Function(String folderId) publishFolderProvider;
  final Future<void> Function(Uint8List sha32) publishFileProvider;
  final void Function(DiskFolderSource source) registerSource;
  final void Function(DiskFolderSource source)? unregisterSource;
  final String registryPath; // disk_folders.json (':memory:' for tests)
  final void Function(String msg)? log;

  /// Persist a folder's current on-disk file list to the durable disk index
  /// (sha -> path/size/mtime/name). Optional; null in tests.
  final void Function(String folderId, List<DiskFile> files)? indexFiles;

  /// Store the piece-hash list of a published file, content-addressed, and
  /// return its sha256 hex. Null in tests / on a host with no archive — the file
  /// is then published without piece metadata and downloaders fall back to a
  /// whole-file fetch, exactly as they did before the piece engine existed.
  final Future<String?> Function(Uint8List blob)? storePieceHashes;

  final Map<String, DiskFolderSource> _sources = {}; // folderId -> source
  final Map<String, String> _dirs = {}; // folderId -> dirPath

  DiskFolderManager({
    required this.folders,
    required this.localState,
    required this.publishFolderProvider,
    required this.publishFileProvider,
    required this.registerSource,
    this.unregisterSource,
    this.indexFiles,
    this.storePieceHashes,
    required this.registryPath,
    this.log,
  });

  List<Map<String, dynamic>> owned() => [
        for (final e in _dirs.entries)
          {
            'folderId': e.key,
            'dir': e.value,
            'files': _sources[e.key]?.fileCount ?? 0,
          }
      ];

  /// A whole storage root (the entire device) must never be a single shared
  /// folder: re-indexing it would walk + hash everything on every sync. Guards
  /// against accidental "share my whole phone" footguns.
  static bool _isUnsafeShareRoot(String dir) {
    var p = dir.replaceAll('\\', '/');
    if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
    const roots = {
      '/', '/storage', '/storage/emulated', '/storage/emulated/0',
      '/sdcard', '/storage/self', '/storage/self/primary', '/mnt',
      '/mnt/sdcard', '/data',
    };
    return roots.contains(p);
  }

  /// Re-adopt previously-registered disk folders (index + serve), without
  /// forcing a publish (the periodic sync handles that).
  Future<void> load() async {
    _loadDownloadRoot();
    var pruned = false;
    for (final entry in _readRegistry().entries) {
      final folderId = entry.key, dir = entry.value;
      if (_isUnsafeShareRoot(dir)) {
        log?.call('disk folder: dropping unsafe whole-storage share $dir');
        pruned = true;
        continue; // not re-adopted; pruned from the registry below
      }
      // Owned folder (holds the master key in .folder.json) → adopt WITH the key
      // so we can sign edits. Downloaded folder (a keyless .torrent.json sidecar)
      // → adopt read-only: we index + serve its bytes from disk, but can't edit.
      final key = _readKeyFile(dir);
      if (key != null) {
        _adoptDir(folderId, dir, key: key);
        continue;
      }
      if (_readSidecar(dir) == folderId) {
        _adoptDir(folderId, dir);
        continue;
      }
      // Neither marker present → the directory is gone or was cleared; prune.
      pruned = true;
    }
    if (pruned) _writeRegistry();
    // Also pick up any torrents that already live under the download root but
    // are not in our registry — this is how "point at an existing folder from a
    // previous install" re-adopts everything under it.
    await adoptRoot();
  }

  /// Register a directory as a disk-backed folder. With [key] it is OWNED (we can
  /// sign edits); without, it is a DOWNLOADED read-only copy we index and serve.
  void _adoptDir(String folderId, String dir, {(String, String, String)? key}) {
    if (_sources.containsKey(folderId)) return;
    if (key != null) {
      folders.keystore.add(FolderKey(folderId, key.$1, key.$2, _now()));
    }
    // Index in the background (yielding) so adopting a large folder at startup
    // never freezes the UI; serving works once the first scan lands.
    final src = DiskFolderSource(dir);
    _sources[folderId] = src;
    _dirs[folderId] = dir;
    registerSource(src);
    unawaited(src.scanAsync());
  }

  /// Register [dirPath] as an owned folder and synchronize it. Returns folderId,
  /// or '' if the path is a whole-storage root (never shareable as one folder).
  Future<String> addFromDisk(String dirPath) async {
    final dir = Directory(dirPath).absolute.path;
    if (_isUnsafeShareRoot(dir)) {
      log?.call('disk folder: refusing to share whole-storage root $dir');
      return '';
    }
    var key = _readKeyFile(dir);
    var isNew = false;
    if (key == null) {
      final kp = NostrCrypto.generateKeyPair();
      final name = dir.split(Platform.pathSeparator).last;
      key = (kp.privateKeyHex, name, kp.publicKeyHex);
      _writeKeyFile(dir, folderId: kp.publicKeyHex, priv: kp.privateKeyHex, name: name);
      isNew = true;
    }
    final priv = key.$1, name = key.$2, folderId = key.$3;
    folders.keystore.add(FolderKey(folderId, priv, name, _now()));
    final src = DiskFolderSource(dir);
    _sources[folderId] = src;
    _dirs[folderId] = dir;
    registerSource(src);
    _writeRegistry();
    if (isNew) await folders.publishInitial(folderId, name: name);
    await sync(folderId);
    return folderId;
  }

  Future<void> syncAll() async {
    for (final id in _sources.keys.toList()) {
      await sync(id);
    }
  }

  // One sync per folder at a time. The periodic 60s sync timer and a manual
  // rescan would otherwise both run scanAsync() on the same source — which
  // mutates shared index state and yields between files — corrupting the diff so
  // an addFile gets skipped (the op then never commits). Serialize per folder:
  // if a run is in flight, chain after it so a "push file then rescan" still
  // applies the new file, but two scans never interleave.
  final Map<String, Future<void>> _inflight = {};

  /// Diff the directory against the published folder state and emit ops only for
  /// what changed; then (re)advertise providers for the folder and its files.
  /// Serialized per folder (see [_inflight]).
  Future<void> sync(String folderId) {
    final running = _inflight[folderId];
    final next = running == null
        ? _syncOnce(folderId)
        : running.then((_) => _syncOnce(folderId),
            onError: (_) => _syncOnce(folderId));
    _inflight[folderId] = next;
    return next.whenComplete(() {
      if (identical(_inflight[folderId], next)) _inflight.remove(folderId);
    });
  }

  Future<void> _syncOnce(String folderId) async {
    final src = _sources[folderId];
    if (src == null) return;
    await src.scanAsync();
    final desired = <String, DiskFile>{for (final f in src.files) f.name: f};
    // Persist the current on-disk inventory to the durable disk index.
    indexFiles?.call(folderId, src.files);

    final state = await localState(folderId);
    final published = <String, FileEntry>{}; // name -> what we published
    for (final e in state.files.values) {
      published[e.name ?? e.sha] = e;
    }

    var changed = 0;
    for (final f in desired.values) {
      final prev = published[f.name];
      // Unchanged file, already carrying its piece hashes → nothing to do.
      //
      // But a file published BEFORE the piece engine existed has no `ps`/`ph`,
      // and a rescan is the only chance it ever gets to acquire them. Without
      // this, every folder that predates the engine would stay stuck on the
      // whole-file path forever — the upgrade would never reach the content that
      // needs it most.
      final needsPieces = storePieceHashes != null && f.size > 0;
      if (prev != null &&
          prev.sha == f.sha &&
          (!needsPieces || prev.hasPieces)) {
        continue;
      }
      if (prev != null && prev.sha != f.sha) {
        await folders.removeFile(folderId, prev.sha, name: f.name);
      }
      // Cut the file into pieces and publish the hash list with it, so a
      // downloader can pull it from several peers at once and check each piece
      // as it lands (docs/torrents.md §8 step 2). Signing this op signs the
      // list. A host with no archive publishes without it, and downloaders fall
      // back to a whole-file fetch.
      int? ps;
      String? ph;
      final store = storePieceHashes;
      if (store != null && f.size > 0) {
        try {
          final size = pieceSizeForFile(f.size);
          final hashes = await pieceHashesOfFile(File(f.path), size);
          if (hashes.isNotEmpty) {
            final sha = await store(packPieceHashes(hashes));
            if (sha != null && sha.length == 64) {
              ps = size;
              ph = sha;
            }
          }
        } catch (e) {
          log?.call('folder: piece hashing failed for ${f.name}: $e');
        }
      }
      await folders.addFile(folderId, f.sha,
          name: f.name,
          size: f.size,
          mime: _mime(f.ext),
          ts: f.mtimeMs > 0 ? f.mtimeMs ~/ 1000 : null,
          pieceSize: ps,
          piecesSha: ph);
      changed++;
    }
    for (final entry in published.entries) {
      // entry.key is the file name, entry.value what we published for it.
      if (!desired.containsKey(entry.key)) {
        await folders.removeFile(folderId, entry.value.sha, name: entry.key);
        changed++;
      }
    }
    if (changed > 0) log?.call('disk folder ${folderId.substring(0, 8)}: $changed change(s) synced');

    // The listing: data/meta.json is what a HUMAN edits, and the signed op-log
    // is a mirror of it. Emitting setMeta here is what lets a stranger read this
    // torrent's title and filter it by category WITHOUT downloading anything —
    // the op-log is what they fetch from the ntorrent link, before any bytes.
    // meta.json wins on every rescan; nothing else writes these fields.
    await _syncListing(folderId, state);

    // Advertise ourselves as a provider of the folder and of each file's bytes.
    // BEST EFFORT — never awaited inline: each DHT publish does an iterative
    // find + STORE and on a flaky link can take tens of seconds, which used to
    // wedge sync() (and the /api/rns/folder/rescan call) for minutes after the
    // signed ops had already committed. republishAll() re-advertises every
    // ~30 min, so a missed/slow publish self-heals. Detach + time-bound it.
    unawaited(_advertise(folderId, desired.values.toList()));
  }

  /// Fire-and-forget provider advertisements, each individually time-bounded so
  /// a stuck DHT publish can't leak an unbounded pending future or block sync.
  Future<void> _advertise(String folderId, List<DiskFile> files) async {
    Future<void> bounded(Future<void> Function() op) async {
      try {
        await op().timeout(const Duration(seconds: 10));
      } catch (_) {/* best effort; republishAll() retries */}
    }

    await bounded(() => publishFolderProvider(folderId));
    for (final f in files) {
      final b = _bytes(f.sha);
      if (b != null) await bounded(() => publishFileProvider(b));
    }
  }

  bool owns(String folderId) => _sources.containsKey(folderId);
  String? dirOf(String folderId) => _dirs[folderId];

  /// `<dir>/data` — where a folder's listing (meta.json + artwork) lives.
  /// Null when we do not serve this folder from disk.
  String? dataDirOf(String folderId) {
    final dir = _dirs[folderId];
    return dir == null ? null : '$dir${Platform.pathSeparator}$kFolderDataDir';
  }

  /// The listing this folder publishes, read from `data/meta.json`. An empty
  /// listing when there is no file, or the file is unreadable/garbage — a folder
  /// without a listing is the normal case, not an error.
  FolderMeta readMeta(String folderId) {
    final data = dataDirOf(folderId);
    if (data == null) return const FolderMeta();
    try {
      final f = File('$data${Platform.pathSeparator}$kFolderMetaFile');
      if (!f.existsSync()) return const FolderMeta();
      return FolderMeta.parse(f.readAsStringSync());
    } catch (e) {
      log?.call('folder: could not read $kFolderDataDir/$kFolderMetaFile: $e');
      return const FolderMeta();
    }
  }

  /// Write the listing. The caller then rescans, which publishes the file (it is
  /// an ordinary file in the folder) and mirrors the fields into the op-log.
  Future<bool> writeMeta(String folderId, FolderMeta meta) async {
    final data = dataDirOf(folderId);
    if (data == null) return false;
    try {
      final dir = Directory(data);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('$data${Platform.pathSeparator}$kFolderMetaFile');
      await f.writeAsString(meta.encode(), flush: true);
      return true;
    } catch (e) {
      log?.call('folder: could not write the listing: $e');
      return false;
    }
  }

  /// Mirror `data/meta.json` into the signed op-log — one setMeta, only when
  /// something actually differs (a setMeta per rescan would grow the op-log
  /// forever for no reason).
  Future<void> _syncListing(String folderId, FolderState state) async {
    final meta = readMeta(folderId);
    if (meta.isEmpty) return; // no listing published: leave the op-log alone

    final sameTitle = (state.title ?? '') == meta.title;
    final sameDesc = (state.desc ?? '') == meta.desc;
    final sameCat = (state.cat ?? '') == meta.cat;
    final sameTags = (state.tags ?? '') == meta.tagsWire;
    final sameAdult = state.adult == meta.adult;
    if (sameTitle && sameDesc && sameCat && sameTags && sameAdult) return;

    await folders.setMeta(
      folderId,
      desc: meta.desc,
      tags: meta.tagsWire,
      title: meta.title,
      cat: meta.cat,
      adult: meta.adult,
    );
    log?.call('disk folder ${folderId.substring(0, 8)}: listing published '
        '("${meta.title}", ${meta.cat}${meta.adult ? ', +18' : ''})');
  }

  /// The real on-disk path of one file inside a folder we serve from disk, by
  /// its sha256 (hex). Null when we don't serve that folder from disk, or don't
  /// have that file. Used to OPEN a file: the bytes are already a real file
  /// here, so there is nothing to export.
  String? filePathOf(String folderId, String shaHex) =>
      _sources[folderId]?.pathOfHex(shaHex);

  /// Stop sharing a disk folder: unregister its source (stop serving its bytes),
  /// drop it from the owned list + registry + keystore so it no longer appears
  /// nor is advertised. The on-disk files and the in-folder key file are LEFT
  /// untouched, so re-adding the same directory resumes with the same folderId.
  void removeDisk(String folderId) {
    final src = _sources.remove(folderId);
    _dirs.remove(folderId);
    if (src != null) unregisterSource?.call(src);
    folders.keystore.remove(folderId);
    _writeRegistry();
    final tag = folderId.length >= 8 ? folderId.substring(0, 8) : folderId;
    log?.call('disk folder $tag: removed (stopped sharing)');
  }

  // ── download root + library (organizing torrents as real dirs on disk) ────

  /// The default when the user has not chosen one (external storage, set by the
  /// host once permissions are known). The user override wins.
  String? defaultDownloadRoot;
  String? _downloadRoot; // user-chosen, persisted
  static const String _kTorrentSidecar = '.torrent.json';

  /// Where downloaded torrents materialize and where organizing subfolders live.
  String? get downloadRoot => _downloadRoot ?? defaultDownloadRoot;

  String get _rootFilePath =>
      '${File(registryPath).parent.path}/download_root.txt';

  void _loadDownloadRoot() {
    if (registryPath == ':memory:') return;
    try {
      final f = File(_rootFilePath);
      if (f.existsSync()) {
        final s = f.readAsStringSync().trim();
        if (s.isNotEmpty) _downloadRoot = s;
      }
    } catch (_) {}
  }

  /// Choose the download folder. Creates it, persists the choice, and adopts any
  /// torrents already sitting under it (real files from a previous install).
  Future<void> setDownloadRoot(String path) async {
    final dir = Directory(path).absolute.path;
    if (_isUnsafeShareRoot(dir)) {
      log?.call('download root: refusing a whole-storage root $dir');
      return;
    }
    _downloadRoot = dir;
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}
    if (registryPath != ':memory:') {
      try {
        File(_rootFilePath).writeAsStringSync(dir);
      } catch (_) {}
    }
    await adoptRoot();
  }

  /// Walk the download root and adopt every torrent directory under it that we
  /// are not already serving (owned via .folder.json, downloaded via the keyless
  /// sidecar). Organizing subfolders are plain directories and are skipped.
  Future<void> adoptRoot() async {
    final root = downloadRoot;
    if (root == null) return;
    final base = Directory(root);
    if (!base.existsSync()) return;
    var found = false;
    try {
      for (final e in base.listSync(recursive: true, followLinks: false)) {
        if (e is! Directory) continue;
        final key = _readKeyFile(e.path);
        if (key != null) {
          if (!_sources.containsKey(key.$3)) {
            _adoptDir(key.$3, e.path, key: key);
            found = true;
          }
          continue;
        }
        final side = _readSidecar(e.path);
        if (side != null && !_sources.containsKey(side)) {
          _adoptDir(side, e.path);
          found = true;
        }
      }
    } catch (e) {
      log?.call('download root: scan failed: $e');
    }
    if (found) _writeRegistry();
  }

  /// Materialize a downloaded torrent as a real directory under the download
  /// root (keyless, read-only), so its files can be written to disk and served
  /// content-addressed. Returns the directory, or null if no root is set. Idempotent.
  Future<String?> addDownloaded(String folderId, String name,
      {String subPath = ''}) async {
    final existing = _dirs[folderId];
    if (existing != null) return existing;
    final root = downloadRoot;
    if (root == null) return null;
    final leaf = _safeName(name.isEmpty ? folderId.substring(0, 8) : name);
    final rel = _normRel(subPath);
    final dir = rel.isEmpty ? '$root/$leaf' : '$root/$rel/$leaf';
    try {
      await Directory(dir).create(recursive: true);
    } catch (e) {
      log?.call('download root: cannot create $dir: $e');
      return null;
    }
    _writeSidecar(dir, folderId, name);
    _adoptDir(folderId, dir);
    _writeRegistry();
    return dir;
  }

  /// Write one downloaded file into a disk-backed folder (creating parent dirs),
  /// then re-index so it is served content-addressed from disk. Returns false if
  /// the folder is not disk-backed here.
  Future<bool> writeDownloadedFile(
      String folderId, String relName, Uint8List bytes) async {
    final dir = _dirs[folderId];
    if (dir == null) return false;
    final rel = _normRel(relName);
    if (rel.isEmpty) return false;
    try {
      final f = File('$dir/$rel');
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      await f.writeAsBytes(bytes);
      unawaited(_sources[folderId]?.scanAsync() ?? Future.value());
      return true;
    } catch (e) {
      log?.call('download root: write $relName failed: $e');
      return false;
    }
  }

  /// One level of the download-folder tree for the wapp's navigable list: the
  /// organizing subfolders directly under [relPath], and the torrents that live
  /// at [relPath]. Torrents registered OUTSIDE the root are listed at the root
  /// level (ungrouped) so nothing is ever hidden.
  Map<String, dynamic> libraryLevel(String relPath) {
    final root = downloadRoot;
    final rel = _normRel(relPath);
    final dirs = <String>{};
    final torrents = <Map<String, dynamic>>[];

    for (final e in _dirs.entries) {
      final fid = e.key, dir = e.value;
      final owned = folders.keystore.owns(fid);
      if (root != null && _isUnder(dir, root)) {
        final r = _relOf(dir, root);
        if (_parentOf(r) == rel) {
          torrents.add(
              {'folderId': fid, 'name': _leafOf(r), 'owned': owned, 'path': rel});
        }
      } else if (rel.isEmpty) {
        torrents.add(
            {'folderId': fid, 'name': _leafOf(dir), 'owned': owned, 'path': ''});
      }
    }

    if (root != null) {
      final base = rel.isEmpty ? root : '$root/$rel';
      try {
        for (final e in Directory(base).listSync(followLinks: false)) {
          if (e is! Directory) continue;
          final leaf = _leafOf(e.path);
          if (leaf.startsWith('.')) continue;
          final isTorrent = File('${e.path}/$kFolderKeyFile').existsSync() ||
              File('${e.path}/$_kTorrentSidecar').existsSync();
          if (!isTorrent) dirs.add(leaf);
        }
      } catch (_) {}
    }

    return {
      'root': root ?? '',
      'path': rel,
      'dirs': [
        for (final d in (dirs.toList()..sort())) {'name': d}
      ],
      'torrents': torrents,
    };
  }

  /// Create an organizing subfolder under the download root. Returns false if no
  /// root is set or the name is unusable.
  Future<bool> createSubfolder(String relPath) async {
    final root = downloadRoot;
    if (root == null) return false;
    final rel = _normRel(relPath);
    if (rel.isEmpty) return false;
    try {
      await Directory('$root/$rel').create(recursive: true);
      return true;
    } catch (e) {
      log?.call('download root: mkdir $rel failed: $e');
      return false;
    }
  }

  /// Move a torrent's directory to [newRelPath] (a subfolder under the root),
  /// keeping its files, key/sidecar and folderId. Re-registers the source at the
  /// new location. Returns false when it isn't disk-backed or the root is unset.
  Future<bool> moveTorrent(String folderId, String newRelPath) async {
    final root = downloadRoot;
    final dir = _dirs[folderId];
    if (root == null || dir == null) return false;
    final leaf = _leafOf(dir);
    final rel = _normRel(newRelPath);
    final destDir = rel.isEmpty ? '$root/$leaf' : '$root/$rel/$leaf';
    if (Directory(destDir).absolute.path == Directory(dir).absolute.path) {
      return true;
    }
    try {
      final parent = Directory(rel.isEmpty ? root : '$root/$rel');
      if (!parent.existsSync()) parent.createSync(recursive: true);
      if (Directory(destDir).existsSync()) {
        log?.call('download root: $destDir already exists');
        return false;
      }
      await Directory(dir).rename(destDir);
    } catch (e) {
      log?.call('download root: move failed: $e');
      return false;
    }
    // Re-point the source at the new directory.
    final old = _sources.remove(folderId);
    if (old != null) unregisterSource?.call(old);
    final src = DiskFolderSource(destDir);
    _sources[folderId] = src;
    _dirs[folderId] = destDir;
    registerSource(src);
    unawaited(src.scanAsync());
    _writeRegistry();
    return true;
  }

  // Path helpers, all on '/'-normalized absolute paths.
  static String _norm(String p) {
    var s = p.replaceAll('\\', '/');
    while (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  static bool _isUnder(String dir, String root) {
    final d = _norm(dir), r = _norm(root);
    return d == r || d.startsWith('$r/');
  }

  static String _relOf(String dir, String root) {
    final d = _norm(dir), r = _norm(root);
    if (d == r) return '';
    return d.startsWith('$r/') ? d.substring(r.length + 1) : d;
  }

  static String _parentOf(String rel) {
    final i = rel.lastIndexOf('/');
    return i < 0 ? '' : rel.substring(0, i);
  }

  static String _leafOf(String path) {
    final s = _norm(path);
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }

  /// Sanitize a single path segment: no separators, no dot-leading (which would
  /// hide it from sharing), bounded length.
  static String _safeName(String name) {
    var s = name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').trim();
    while (s.startsWith('.')) s = s.substring(1);
    if (s.isEmpty) s = 'torrent';
    return s.length > 80 ? s.substring(0, 80) : s;
  }

  /// Sanitize a relative path: drop empty / '.' / '..' segments and dot-leading
  /// ones, so a hostile name can never escape the root.
  static String _normRel(String rel) {
    final parts = <String>[];
    for (final raw in _norm(rel).split('/')) {
      final seg = raw.trim();
      if (seg.isEmpty || seg == '.' || seg == '..' || seg.startsWith('.')) {
        continue;
      }
      parts.add(seg.replaceAll(RegExp(r'[\\\x00-\x1f]'), '_'));
    }
    return parts.join('/');
  }

  String? _readSidecar(String dir) {
    try {
      final f = File('$dir/$_kTorrentSidecar');
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync());
      if (m is Map && m['folderId'] is String) return m['folderId'] as String;
    } catch (_) {}
    return null;
  }

  void _writeSidecar(String dir, String folderId, String name) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      File('$dir/$_kTorrentSidecar').writeAsStringSync(
          jsonEncode({'folderId': folderId, 'name': name}));
    } catch (e) {
      log?.call('disk folder: cannot write sidecar: $e');
    }
  }

  // ── key file + registry ─────────────────────────────────────────────────

  // returns (privHex, name, folderId) or null
  (String, String, String)? _readKeyFile(String dir) {
    try {
      final f = File('$dir/$kFolderKeyFile');
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) return null;
      final id = m['folderId'], priv = m['priv'];
      if (id is! String || priv is! String) return null;
      return (priv, (m['name'] ?? '').toString(), id);
    } catch (_) {
      return null;
    }
  }

  void _writeKeyFile(String dir,
      {required String folderId, required String priv, required String name}) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      File('$dir/$kFolderKeyFile').writeAsStringSync(
          jsonEncode({'folderId': folderId, 'priv': priv, 'name': name}));
    } catch (e) {
      log?.call('disk folder: cannot write key file: $e');
    }
  }

  Map<String, String> _readRegistry() {
    if (registryPath == ':memory:') return {};
    try {
      final f = File(registryPath);
      if (!f.existsSync()) return {};
      final m = jsonDecode(f.readAsStringSync());
      if (m is Map) return {for (final e in m.entries) '${e.key}': '${e.value}'};
    } catch (_) {}
    return {};
  }

  void _writeRegistry() {
    if (registryPath == ':memory:') return;
    try {
      final parent = File(registryPath).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      File(registryPath).writeAsStringSync(jsonEncode(_dirs));
    } catch (_) {}
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Uint8List? _bytes(String hex) {
    if (hex.length != 64) return null;
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  static String? _mime(String ext) {
    switch (ext) {
      case 'mp3': return 'audio/mpeg';
      case 'flac': return 'audio/flac';
      case 'mp4': return 'video/mp4';
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      default: return null;
    }
  }
}
