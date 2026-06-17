/*
 * FolderSubscriptions — a consumer's per-folder download state. For each folder
 * the user follows we remember whether to auto-sync and which logical files
 * (by name) they downloaded, with the sha they hold. Auto-sync compares the
 * folder's current name->sha to this and re-fetches the ones that changed.
 *
 * Persisted as plain JSON (folder_subscriptions.json under profile storage),
 * path-injectable (':memory:' for tests). Headless.
 */
import 'dart:convert';
import 'dart:io';

class FolderSub {
  bool autoSync;
  final Map<String, String> downloaded; // logical name -> sha (hex)
  FolderSub({this.autoSync = false, Map<String, String>? downloaded})
      : downloaded = downloaded ?? {};

  Map<String, dynamic> toJson() => {'autoSync': autoSync, 'downloaded': downloaded};
  static FolderSub fromJson(Object? o) {
    if (o is! Map) return FolderSub();
    final d = <String, String>{};
    final raw = o['downloaded'];
    if (raw is Map) {
      raw.forEach((k, v) => d['$k'] = '$v');
    }
    return FolderSub(autoSync: o['autoSync'] == true, downloaded: d);
  }
}

class FolderSubscriptions {
  FolderSubscriptions._(this._path);
  final String _path;
  final Map<String, FolderSub> _subs = {}; // folderId -> sub

  factory FolderSubscriptions.open(String path) {
    final s = FolderSubscriptions._(path);
    s._load();
    return s;
  }

  void _load() {
    if (_path == ':memory:') return;
    try {
      final f = File(_path);
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync());
      if (m is Map) {
        m.forEach((k, v) => _subs['$k'] = FolderSub.fromJson(v));
      }
    } catch (_) {}
  }

  void _save() {
    if (_path == ':memory:') return;
    try {
      final parent = File(_path).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      File(_path).writeAsStringSync(
          jsonEncode({for (final e in _subs.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }

  FolderSub _of(String folderId) =>
      _subs.putIfAbsent(folderId, () => FolderSub());

  bool autoSyncOf(String folderId) => _subs[folderId]?.autoSync ?? false;

  void setAutoSync(String folderId, bool on) {
    _of(folderId).autoSync = on;
    _save();
  }

  Map<String, String> downloadedOf(String folderId) =>
      Map.unmodifiable(_subs[folderId]?.downloaded ?? const {});

  /// Record that we downloaded logical file [name] at content [sha].
  void recordDownload(String folderId, String name, String sha) {
    _of(folderId).downloaded[name] = sha;
    _save();
  }

  bool isSubscribed(String folderId) => _subs.containsKey(folderId);
  List<String> folderIds() => _subs.keys.toList();

  Map<String, dynamic> status(String folderId) {
    final s = _subs[folderId];
    return {
      'subscribed': s != null,
      'autoSync': s?.autoSync ?? false,
      'downloaded': s?.downloaded.length ?? 0,
    };
  }
}
