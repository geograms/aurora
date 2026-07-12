/*
 * ProfileService — singleton managing iwi profiles.
 *
 * Persists a list of [IwiProfile]s to `profiles.json` at the geogram
 * root (see `geogramRootStorage()` in storage_paths.dart). Tracks a
 * single active profile id and publishes changes via
 * [activeProfileNotifier] so the launcher, storage paths, and any
 * other listener can rebuild when the user switches identities.
 *
 * The parent geogram project has a much bigger ProfileService with
 * NIP-05 registry, station mode, vanity keygen, encrypted archives
 * and so on. iwi intentionally stays minimal: create / list / switch
 * / delete. Everything else is a future phase.
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:reticulum/reticulum.dart' as reticulum;

import 'iwi_profile.dart';
import '../util/nostr_key_generator.dart';
import '../services/preferences_service.dart';
import 'identity_backup.dart';
import 'profile_db.dart';
import 'profile_storage.dart';
import 'storage_paths.dart';

class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const String _profilesFile = 'profiles.json';
  static const String _activeKey = 'active';

  /// All profiles currently known to the launcher, ordered by
  /// creation time (oldest first). Cached after the first [load].
  List<IwiProfile> _profiles = const [];

  /// Id of the currently-active profile, or null when the launcher is
  /// in "no profile yet" state. Persisted inside `profiles.json`.
  String? _activeId;

  /// Emits the active profile id on every switch (or null after
  /// deletion of the last profile). Widgets that care about the
  /// active identity (launcher grid, storage paths, App Creator
  /// Settings identity row, etc.) listen here and rebuild.
  final ValueNotifier<String?> activeProfileNotifier =
      ValueNotifier<String?>(null);

  /// Bumped on ANY profile-data change (switch, edit, add, delete). Widgets
  /// that render profile fields (AppBar label, avatar) listen here so an
  /// in-place edit of the active profile — which doesn't change the active id —
  /// still triggers a rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// True once [load] has completed at least once. Used by `main.dart`
  /// to decide whether to show WelcomePage or the launcher on boot.
  bool get isLoaded => _loaded;
  bool _loaded = false;

  /// True when at least one profile has been saved. Drives the
  /// "show WelcomePage first" gate.
  bool get hasProfiles => _profiles.isNotEmpty;

  List<IwiProfile> get profiles => List.unmodifiable(_profiles);

  /// The active profile, or null if none is selected yet. Called from
  /// storage_paths.dart to resolve profile-scoped folders.
  IwiProfile? get activeProfile {
    final id = _activeId;
    if (id == null) return null;
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Read profiles.json from disk into memory. Safe to call more than
  /// once; the second call is a no-op so the service can be used as a
  /// lazy singleton from anywhere that needs profile state.
  Future<void> load() async {
    if (_loaded) return;
    // Route every reticulum-package database open (media archive, disk
    // index, serve stats, relay events, coin wallet) through the profile
    // opener so encrypted profiles get their SQLCipher keys applied. Must
    // happen before any store is constructed; this boot task runs before
    // wapp/reticulum autostart on both UI and headless engines.
    reticulum.dbOpener = openProfileDb;
    final root = geogramRootStorage();
    await root.createDirectory('');
    final existing = await root.readJson(_profilesFile);
    if (existing != null) {
      final list = existing['profiles'];
      if (list is List) {
        _profiles = list
            .whereType<Map>()
            .map((m) => IwiProfile.fromJson(m.cast<String, dynamic>()))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
      final active = existing[_activeKey];
      if (active is String && active.isNotEmpty) {
        _activeId = active;
      }
    }
    // If we loaded profiles but no active id is set (first time on
    // this machine after a manual copy, say), default to the oldest.
    if (_activeId == null && _profiles.isNotEmpty) {
      _activeId = _profiles.first.id;
    }
    _loaded = true;
    activeProfileNotifier.value = _activeId;
    // Ensure existing identities are mirrored to survives-uninstall storage on
    // boot too (not only when a profile changes), so users who installed before
    // this feature — or who never edit their profile — still get the safety net.
    if (_profiles.isNotEmpty) {
      final pass =
          PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
      unawaited(IdentityBackup.instance.backupAll(_profiles, passphrase: pass));
    }
  }

  /// Generate a fresh key pair and return an unpersisted preview.
  /// The welcome page iterates on these without writing anything to
  /// disk until the user hits Continue.
  IwiProfile generatePreview({String nickname = ''}) {
    final keys = NostrKeyGenerator.generateKeyPair();
    return IwiProfile(
      id: keys.callsign,
      nickname: nickname,
      callsign: keys.callsign,
      npub: keys.npub,
      nsec: keys.nsec,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Build an IwiProfile from an imported nsec. Throws
  /// [ArgumentError] if the nsec is malformed. Does not persist.
  IwiProfile buildFromNsec(String nsec, {String nickname = ''}) {
    if (!NostrKeyGenerator.isValidNsec(nsec)) {
      throw ArgumentError('Invalid nsec — must be a bech32 nsec1… string');
    }
    final npub = NostrKeyGenerator.derivePublicKey(nsec);
    if (npub == null) {
      throw ArgumentError('Could not derive npub from nsec');
    }
    final callsign = NostrKeyGenerator.deriveCallsign(npub);
    return IwiProfile(
      id: callsign,
      nickname: nickname,
      callsign: callsign,
      npub: npub,
      nsec: nsec,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Persist a new (or edited) profile to disk and mark it active.
  /// Safe to call with a profile whose id already exists — that
  /// replaces the previous entry in place.
  Future<void> saveAndActivate(IwiProfile profile) async {
    final without = _profiles.where((p) => p.id != profile.id).toList();
    without.add(profile);
    without.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _profiles = without;
    _activeId = profile.id;
    await _persist();
    activeProfileNotifier.value = _activeId;
    revision.value++;
  }

  /// Replace an existing profile in place (same [id]) without changing
  /// which profile is active — used by the profile editor to persist
  /// nickname/description/colour/avatar edits. Fires the notifier so the
  /// AppBar label, avatar and any other listeners rebuild immediately.
  Future<void> update(IwiProfile profile) async {
    if (_profiles.every((p) => p.id != profile.id)) {
      throw StateError('Unknown profile id: ${profile.id}');
    }
    _profiles = _profiles
        .map((p) => p.id == profile.id ? profile : p)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await _persist();
    revision.value++;
  }

  /// Per-profile storage root (`devices/<id>/`) for any profile id — used
  /// to read/write that profile's avatar image. (cf. [activeProfileStorage].)
  ProfileStorage storageForProfile(String id) =>
      ScopedProfileStorage(geogramRootStorage(), 'devices/$id');

  /// Switch the active profile to [id]. Fires the notifier so the
  /// launcher rescans. Throws [StateError] if the id is unknown.
  Future<void> switchTo(String id) async {
    if (_profiles.every((p) => p.id != id)) {
      throw StateError('Unknown profile id: $id');
    }
    if (_activeId == id) return;
    _activeId = id;
    await _persist();
    activeProfileNotifier.value = id;
    revision.value++;
  }

  /// Remove [id] from the on-disk list. If it was the active profile,
  /// falls back to the oldest remaining. If no profiles remain the
  /// active id becomes null and [hasProfiles] turns false, which
  /// drops the app back into welcome-page state on the next rebuild.
  Future<void> delete(String id) async {
    _profiles = _profiles.where((p) => p.id != id).toList();
    if (_activeId == id) {
      _activeId = _profiles.isNotEmpty ? _profiles.first.id : null;
    }
    await _persist();
    activeProfileNotifier.value = _activeId;
    revision.value++;
  }

  Future<void> _persist() async {
    final root = geogramRootStorage();
    await root.writeJson(_profilesFile, {
      'profiles': _profiles.map((p) => p.toJson()).toList(),
      _activeKey: _activeId,
    });
    // Mirror the identity (nsec) to survives-uninstall storage so a reinstall /
    // data wipe can restore it. Best-effort and fire-and-forget — a missing
    // storage permission must never break a profile save.
    final pass =
        PreferencesService.instanceSync?.identityBackupPassphrase ?? '';
    unawaited(
        IdentityBackup.instance.backupAll(_profiles, passphrase: pass));
  }

  /// Absolute path to the active profile's per-profile storage root
  /// (i.e. `<aurora root>/devices/<id>/`). Called from
  /// storage_paths.dart when resolving apps/ and wapps/ per profile.
  /// Returns null when there is no active profile.
  ProfileStorage? activeProfileStorage() {
    final active = activeProfile;
    if (active == null) return null;
    return ScopedProfileStorage(
      geogramRootStorage(),
      'devices/${active.id}',
    );
  }
}
