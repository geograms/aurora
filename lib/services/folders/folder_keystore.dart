/*
 * FolderKeystore — stores the MASTER keypairs for folders this device OWNS, so
 * the owner can keep editing the folder and managing its admins. Admins do NOT
 * need an entry here: they sign edits with their own profile key.
 *
 * Plain JSON at <path> (folders.json under profile storage), same trust model as
 * profiles.json (nsec already lives there in the clear). Path-injectable so tests
 * can use ':memory:'. Headless: dart:io + dart:convert + nostr_crypto only.
 */
import 'dart:convert';

import '../../profile/secure_file.dart';
import '../../util/nostr_crypto.dart';

class FolderKey {
  final String folderId; // hex master pubkey
  final String priv; // hex master private key
  final String name;
  final int createdAt; // unix seconds

  const FolderKey(this.folderId, this.priv, this.name, this.createdAt);

  String get npub => NostrCrypto.encodeNpub(folderId);

  Map<String, dynamic> toJson() =>
      {'folderId': folderId, 'priv': priv, 'name': name, 'createdAt': createdAt};

  static FolderKey? fromJson(Object? o) {
    if (o is! Map) return null;
    final f = o['folderId'], p = o['priv'];
    if (f is! String || p is! String) return null;
    return FolderKey(f, p, (o['name'] ?? '').toString(),
        o['createdAt'] is int ? o['createdAt'] as int : 0);
  }
}

class FolderKeystore {
  FolderKeystore._(this._path);

  final String _path; // ':memory:' = no disk
  final Map<String, FolderKey> _keys = {}; // folderId -> key

  /// Open (loading any existing folders.json). Use ':memory:' for tests.
  factory FolderKeystore.open(String path) {
    final ks = FolderKeystore._(path);
    ks._load();
    return ks;
  }

  void _load() {
    if (_path == ':memory:') return;
    try {
      // Folder master keys are write-authority secrets: encrypted at rest
      // when the profile is encrypted, plain file otherwise.
      final content = SecureProfileFile.readString(_path);
      if (content == null) return;
      final list = jsonDecode(content);
      if (list is List) {
        for (final e in list) {
          final k = FolderKey.fromJson(e);
          if (k != null) _keys[k.folderId] = k;
        }
      }
    } catch (_) {/* corrupt/absent — start empty, never wipe on read */}
  }

  void _save() {
    if (_path == ':memory:') return;
    try {
      SecureProfileFile.writeString(
          _path, jsonEncode([for (final k in _keys.values) k.toJson()]));
    } catch (_) {/* best-effort */}
  }

  FolderKey add(FolderKey key) {
    _keys[key.folderId] = key;
    _save();
    return key;
  }

  FolderKey? get(String folderId) => _keys[folderId];
  bool owns(String folderId) => _keys.containsKey(folderId);
  List<FolderKey> all() => _keys.values.toList();

  void remove(String folderId) {
    if (_keys.remove(folderId) != null) _save();
  }
}
