/*
 * IdentityBackup — keep the user's identity (the nsec) safe across uninstall.
 *
 * The nsec IS the identity: npub, callsign, and the ability to sign/decrypt all
 * derive from it. It normally lives only in `profiles.json` under the app's
 * private support dir, which Android deletes on uninstall — so a reinstall (or a
 * data wipe) loses the identity forever.
 *
 * This service mirrors the identity-only subset of every profile to a location
 * that SURVIVES uninstall:
 *   - Android: /storage/emulated/0/Aurora/identity-backup.json (public storage,
 *     reachable via MANAGE_EXTERNAL_STORAGE — the same access the disk-folder
 *     picker uses). Android keeps this when the app is removed.
 *   - Desktop: $HOME/.config/aurora/identity-backup.json (deliberately OUTSIDE
 *     ~/.local/share/aurora so wiping app data doesn't take the backup with it).
 *
 * The backup is plaintext by default (always restorable, zero friction). If the
 * user sets a passphrase it is AES-256-GCM encrypted with a PBKDF2-HMAC-SHA256
 * key. We never store the passphrase in the backup — the user must remember it
 * (the device keystore can't help: it is wiped on uninstall too).
 *
 * Writes are best-effort and atomic (tmp + rename); failures are logged, never
 * thrown into the caller, so a missing permission never breaks profile saves.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../platform/platform.dart' as platform;
import '../services/android_permissions_service.dart';
import '../services/log_service.dart';
import 'iwi_profile.dart';

/// One identity restorable from a backup file.
class RestorableIdentity {
  final String callsign;
  final String npub;
  final String nsec;
  final String nickname;
  final int createdAt;
  const RestorableIdentity({
    required this.callsign,
    required this.npub,
    required this.nsec,
    required this.nickname,
    required this.createdAt,
  });

  factory RestorableIdentity.fromJson(Map<String, dynamic> j) => RestorableIdentity(
        callsign: (j['callsign'] as String?) ?? '',
        npub: (j['npub'] as String?) ?? '',
        nsec: (j['nsec'] as String?) ?? '',
        nickname: (j['nickname'] as String?) ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
}

/// Thrown by [IdentityBackup.readBackup] when the file is encrypted and the
/// passphrase is missing or wrong (or the file is corrupt).
class BadPassphrase implements Exception {
  final String message;
  const BadPassphrase(this.message);
  @override
  String toString() => message;
}

class IdentityBackup {
  IdentityBackup._();
  static final IdentityBackup instance = IdentityBackup._();

  static const String _fileName = 'identity-backup.json';
  static const int _kdfIters = 120000;

  bool get _isAndroid => platform.platformName() == 'android';

  /// Directory for the backup, or null when it isn't reachable (e.g. Android
  /// all-files-access not granted yet). Creates it when [create] is true.
  Future<String?> backupDir({bool create = false}) async {
    if (_isAndroid) {
      if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
        return null;
      }
      for (final root in const ['/storage/emulated/0', '/sdcard']) {
        if (!await Directory(root).exists()) continue;
        final d = Directory('$root/Aurora');
        if (await d.exists()) return d.path;
        if (create) {
          try {
            await d.create(recursive: true);
            return d.path;
          } catch (_) {
            return null;
          }
        }
      }
      return null;
    }
    final home = platform.homeDir();
    if (home == null || home.isEmpty) return null;
    final d = Directory('$home/.config/aurora');
    if (create && !await d.exists()) {
      try {
        await d.create(recursive: true);
      } catch (_) {
        return null;
      }
    }
    return d.path;
  }

  Future<File?> _file({bool create = false}) async {
    final dir = await backupDir(create: create);
    if (dir == null) return null;
    return File('$dir/$_fileName');
  }

  /// Human-readable path of the backup file (for the UI), or null if unreachable.
  Future<String?> backupPath() async => (await _file())?.path;

  /// True when a backup file exists and is reachable.
  Future<bool> backupExists() async {
    final f = await _file();
    return f != null && await f.exists();
  }

  /// True when the existing backup is passphrase-encrypted.
  Future<bool> isEncrypted() async {
    final f = await _file();
    if (f == null || !await f.exists()) return false;
    try {
      final raw = jsonDecode(await f.readAsString());
      return raw is Map && raw['encrypted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Mirror the identity subset of [profiles] to the survives-uninstall file.
  /// Best-effort: never throws. A missing permission / unreachable path is a
  /// silent no-op so profile saves are never blocked.
  Future<void> backupAll(List<IwiProfile> profiles,
      {String passphrase = ''}) async {
    try {
      if (profiles.isEmpty) return;
      final f = await _file(create: true);
      if (f == null) return;
      final identities = profiles
          .map((p) => {
                'callsign': p.callsign,
                'npub': p.npub,
                'nsec': p.nsec,
                'nickname': p.nickname,
                'createdAt': p.createdAt,
              })
          .toList();
      Map<String, dynamic> payload;
      if (passphrase.isNotEmpty) {
        payload = await _encrypt(jsonEncode({'profiles': identities}), passphrase);
      } else {
        payload = {'encrypted': false, 'profiles': identities};
      }
      payload['version'] = 1;
      payload['savedAt'] = DateTime.now().toUtc().toIso8601String();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      LogService.instance.add('IdentityBackup: backup failed: $e');
    }
  }

  /// Read the backed-up identities. Returns [] when there is no backup. Throws
  /// [BadPassphrase] when the file is encrypted and [passphrase] is wrong/missing.
  Future<List<RestorableIdentity>> readBackup({String passphrase = ''}) async {
    final f = await _file();
    if (f == null || !await f.exists()) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(await f.readAsString());
    } catch (_) {
      throw const BadPassphrase('Backup file is corrupt');
    }
    if (decoded is! Map) return const [];
    final raw = decoded.cast<String, dynamic>();
    List<dynamic> identities;
    if (raw['encrypted'] == true) {
      if (passphrase.isEmpty) {
        throw const BadPassphrase('This backup is passphrase-protected');
      }
      final inner = await _decrypt(raw, passphrase);
      final innerMap = jsonDecode(inner);
      identities = (innerMap is Map ? innerMap['profiles'] : null) as List? ??
          const [];
    } else {
      identities = (raw['profiles'] as List?) ?? const [];
    }
    return identities
        .whereType<Map>()
        .map((m) => RestorableIdentity.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // ── crypto: AES-256-GCM with a PBKDF2-HMAC-SHA256 key ────────────────────
  Future<Map<String, dynamic>> _encrypt(
      String plaintext, String passphrase) async {
    final salt = _randomBytes(16);
    final key = await _deriveKey(passphrase, salt, _kdfIters);
    final algo = AesGcm.with256bits();
    final nonce = algo.newNonce();
    final box = await algo.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return {
      'encrypted': true,
      'kdf': {
        'algo': 'pbkdf2-hmac-sha256',
        'iters': _kdfIters,
        'salt': base64Encode(salt),
      },
      'iv': base64Encode(nonce),
      'mac': base64Encode(box.mac.bytes),
      'ct': base64Encode(box.cipherText),
    };
  }

  Future<String> _decrypt(Map<String, dynamic> raw, String passphrase) async {
    try {
      final kdf = (raw['kdf'] as Map).cast<String, dynamic>();
      final salt = base64Decode(kdf['salt'] as String);
      final iters = (kdf['iters'] as num?)?.toInt() ?? _kdfIters;
      final key = await _deriveKey(passphrase, salt, iters);
      final algo = AesGcm.with256bits();
      final box = SecretBox(
        base64Decode(raw['ct'] as String),
        nonce: base64Decode(raw['iv'] as String),
        mac: Mac(base64Decode(raw['mac'] as String)),
      );
      final clear = await algo.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      throw const BadPassphrase('Wrong passphrase or corrupt backup');
    }
  }

  Future<SecretKey> _deriveKey(
      String passphrase, List<int> salt, int iters) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iters,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}
