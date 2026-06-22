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
import 'folder_service.dart';
import 'folder_state.dart';

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
    var pruned = false;
    for (final entry in _readRegistry().entries) {
      final folderId = entry.key, dir = entry.value;
      if (_isUnsafeShareRoot(dir)) {
        log?.call('disk folder: dropping unsafe whole-storage share $dir');
        pruned = true;
        continue; // not re-adopted; pruned from the registry below
      }
      final key = _readKeyFile(dir);
      if (key == null) continue;
      folders.keystore
          .add(FolderKey(folderId, key.$1, key.$2, _now()));
      // Index in the background (yielding) so adopting a large shared folder at
      // startup never freezes the UI; serving works once the first scan lands.
      final src = DiskFolderSource(dir);
      _sources[folderId] = src;
      _dirs[folderId] = dir;
      registerSource(src);
      unawaited(src.scanAsync());
    }
    if (pruned) _writeRegistry();
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
    final published = <String, String>{}; // name -> sha
    for (final e in state.files.values) {
      published[e.name ?? e.sha] = e.sha;
    }

    var changed = 0;
    for (final f in desired.values) {
      final prev = published[f.name];
      if (prev == f.sha) continue;
      if (prev != null) await folders.removeFile(folderId, prev, name: f.name);
      await folders.addFile(folderId, f.sha,
          name: f.name,
          size: f.size,
          mime: _mime(f.ext),
          ts: f.mtimeMs > 0 ? f.mtimeMs ~/ 1000 : null);
      changed++;
    }
    for (final entry in published.entries) {
      // entry.key is the file name, entry.value its sha.
      if (!desired.containsKey(entry.key)) {
        await folders.removeFile(folderId, entry.value, name: entry.key);
        changed++;
      }
    }
    if (changed > 0) log?.call('disk folder ${folderId.substring(0, 8)}: $changed change(s) synced');

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
