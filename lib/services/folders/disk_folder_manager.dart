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
  final String registryPath; // disk_folders.json (':memory:' for tests)
  final void Function(String msg)? log;

  final Map<String, DiskFolderSource> _sources = {}; // folderId -> source
  final Map<String, String> _dirs = {}; // folderId -> dirPath

  DiskFolderManager({
    required this.folders,
    required this.localState,
    required this.publishFolderProvider,
    required this.publishFileProvider,
    required this.registerSource,
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

  /// Re-adopt previously-registered disk folders (index + serve), without
  /// forcing a publish (the periodic sync handles that).
  Future<void> load() async {
    for (final entry in _readRegistry().entries) {
      final folderId = entry.key, dir = entry.value;
      final key = _readKeyFile(dir);
      if (key == null) continue;
      folders.keystore
          .add(FolderKey(folderId, key.$1, key.$2, _now()));
      final src = DiskFolderSource(dir)..scan();
      _sources[folderId] = src;
      _dirs[folderId] = dir;
      registerSource(src);
    }
  }

  /// Register [dirPath] as an owned folder and synchronize it. Returns folderId.
  Future<String> addFromDisk(String dirPath) async {
    final dir = Directory(dirPath).absolute.path;
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

  /// Diff the directory against the published folder state and emit ops only for
  /// what changed; then (re)advertise providers for the folder and its files.
  Future<void> sync(String folderId) async {
    final src = _sources[folderId];
    if (src == null) return;
    src.scan();
    final desired = <String, DiskFile>{for (final f in src.files) f.name: f};

    final state = await localState(folderId);
    final published = <String, String>{}; // name -> sha
    for (final e in state.files.values) {
      published[e.name ?? e.sha] = e.sha;
    }

    var changed = 0;
    for (final f in desired.values) {
      final prev = published[f.name];
      if (prev == f.sha) continue;
      if (prev != null) await folders.removeFile(folderId, prev);
      await folders.addFile(folderId, f.sha, name: f.name, size: f.size, mime: _mime(f.ext));
      changed++;
    }
    for (final entry in published.entries) {
      if (!desired.containsKey(entry.key)) {
        await folders.removeFile(folderId, entry.value);
        changed++;
      }
    }

    // Advertise ourselves as a provider of the folder and of each file's bytes.
    await publishFolderProvider(folderId);
    for (final f in desired.values) {
      final b = _bytes(f.sha);
      if (b != null) await publishFileProvider(b);
    }
    if (changed > 0) log?.call('disk folder ${folderId.substring(0, 8)}: $changed change(s) synced');
  }

  bool owns(String folderId) => _sources.containsKey(folderId);
  String? dirOf(String folderId) => _dirs[folderId];

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
