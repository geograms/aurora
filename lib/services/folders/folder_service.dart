/*
 * FolderService — create and manage IPNS-like mutable folders, and browse them.
 *
 * Transport-agnostic: constructed with injected [publish] (send a signed event
 * to the relay) and [query] (fetch events by filter), so tests back it with a
 * RelayEventStore directly and the app backs it with rns_service.relayPublish/
 * relayQuery. Owner edits are signed with the folder's stored MASTER key; edits
 * to folders this device doesn't own are signed with the active profile key
 * ([adminPrivHex]) and only take effect if that key is in the folder's key-set.
 * Only the owner (holder of the master key) can grant/revoke admins.
 */
import '../social/relay_event_store.dart' show NostrFilter;
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
import 'folder_event.dart';
import 'folder_keystore.dart';
import 'folder_state.dart';

typedef FolderPublish = Future<bool> Function(NostrEvent event);
typedef FolderQuery = Future<List<NostrEvent>> Function(NostrFilter filter);

class FolderService {
  final FolderKeystore keystore;
  final FolderPublish publish;
  final FolderQuery query;

  /// The active profile's private key (hex), used to sign edits to folders this
  /// device doesn't own (acting as an authorized admin). Null if no identity.
  final String? Function() adminPrivHex;
  final void Function(String msg)? log;

  /// Clock (unix seconds) — injectable for deterministic tests; defaults to the
  /// wall clock.
  final int Function()? nowSec;

  FolderService({
    required this.keystore,
    required this.publish,
    required this.query,
    required this.adminPrivHex,
    this.nowSec,
    this.log,
  });

  int _now() =>
      nowSec?.call() ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Our personal npub (from the active profile key) — stamped into folders we
  /// own so peers can later message the admin directly. Null if no identity.
  String? _ownerNpub() {
    final p = adminPrivHex();
    if (p == null || p.isEmpty) return null;
    try {
      return NostrCrypto.encodeNpub(NostrCrypto.derivePublicKey(p));
    } catch (_) {
      return null;
    }
  }

  /// Generate + store a new folder master key, returning its folderId (hex
  /// master pubkey; npub is the shareable address). Synchronous — no network.
  /// Call [publishInitial] to put its first key-set + metadata on the relay.
  String createKey(String name) {
    final kp = NostrCrypto.generateKeyPair();
    keystore.add(FolderKey(kp.publicKeyHex, kp.privateKeyHex, name, _now()));
    return kp.publicKeyHex;
  }

  /// Publish the initial (empty) key-set + a setMeta op for a folder we own.
  Future<void> publishInitial(String folderId,
      {required String name, String desc = ''}) async {
    final owner = keystore.get(folderId);
    if (owner == null) return;
    await publish(buildKeyset(owner.priv, const [], createdAt: _now()));
    await publish(buildOp(owner.priv, folderId,
        opSetMeta(
            name: name, desc: desc.isEmpty ? null : desc, owner: _ownerNpub()),
        createdAt: _now()));
  }

  /// Create a new folder (key + initial relay state); returns its folderId.
  Future<String> createFolder({required String name, String desc = ''}) async {
    final folderId = createKey(name);
    await publishInitial(folderId, name: name, desc: desc);
    return folderId;
  }

  /// The key to sign an edit with: the master key if we own the folder, else the
  /// active profile key (which must be an authorized admin to take effect).
  String? _signer(String folderId) =>
      keystore.get(folderId)?.priv ?? adminPrivHex();

  Future<bool> _emitOp(String folderId, Map<String, dynamic> op) async {
    final priv = _signer(folderId);
    if (priv == null) {
      log?.call('folder: no signing key for $folderId');
      return false;
    }
    return publish(buildOp(priv, folderId, op, createdAt: _now()));
  }

  Future<bool> addFile(String folderId, String shaHex,
          {String? name, String? desc, String? mime, int? size, int? ts}) =>
      _emitOp(folderId,
          opAddFile(shaHex, name: name, desc: desc, mime: mime, size: size, ts: ts));

  Future<bool> removeFile(String folderId, String shaHex, {String? name}) =>
      _emitOp(folderId, opRmFile(shaHex, name: name));

  Future<bool> setMeta(String folderId, {String? name, String? desc, String? tags}) =>
      // Stamp/refresh the owner npub when we hold the master key, so existing
      // folders gain it on the next edit (for later admin messaging).
      _emitOp(folderId,
          opSetMeta(
              name: name,
              desc: desc,
              tags: tags,
              owner: keystore.owns(folderId) ? _ownerNpub() : null));

  Future<bool> linkFolder(String folderId, String targetFolderId,
          {String? name}) =>
      _emitOp(folderId, opLink(targetFolderId, name: name));

  Future<bool> unlinkFolder(String folderId, String targetFolderId) =>
      _emitOp(folderId, opUnlink(targetFolderId));

  // ── Owner-only key-set management ───────────────────────────────────────────

  Future<NostrEvent?> _currentKeyset(String folderId) async {
    final r = await query(NostrFilter(
        authors: [folderId], kinds: [kKindFolderKeyset], limit: 1));
    return r.isEmpty ? null : r.first;
  }

  /// A keyset republish timestamp strictly greater than the current one (the
  /// keyset is a replaceable event; an equal/older timestamp would be dropped).
  int _nextKeysetTs(NostrEvent? ks) {
    final t = _now();
    return (ks != null && t <= ks.createdAt) ? ks.createdAt + 1 : t;
  }

  /// Authorize [adminPubHex] (their npub's hex) as a moderator/contributor.
  Future<bool> grantAdmin(String folderId, String adminPubHex,
      {String role = FolderRole.contributor}) async {
    final owner = keystore.get(folderId);
    if (owner == null) {
      log?.call('folder: only the owner can grant admins');
      return false;
    }
    final ks = await _currentKeyset(folderId);
    final admins = [...reduceFolder(folderId, ks, const []).admins];
    final idx = admins.indexWhere((a) => a.pubkey == adminPubHex);
    if (idx >= 0) {
      // Re-grant: keep original addedAt, clear any revocation.
      admins[idx] = AdminEntry(adminPubHex, role, admins[idx].addedAt);
    } else {
      admins.add(AdminEntry(adminPubHex, role, _now()));
    }
    return publish(buildKeyset(owner.priv, admins, createdAt: _nextKeysetTs(ks)));
  }

  /// Revoke an admin's future edits (their past, authorized edits remain).
  Future<bool> revokeAdmin(String folderId, String adminPubHex) async {
    final owner = keystore.get(folderId);
    if (owner == null) return false;
    final ks = await _currentKeyset(folderId);
    final admins = [...reduceFolder(folderId, ks, const []).admins];
    final idx =
        admins.indexWhere((a) => a.pubkey == adminPubHex && a.revokedAt == null);
    if (idx < 0) return false;
    final a = admins[idx];
    admins[idx] = AdminEntry(a.pubkey, a.role, a.addedAt, _now());
    return publish(buildKeyset(owner.priv, admins, createdAt: _nextKeysetTs(ks)));
  }

  // ── Browsing ────────────────────────────────────────────────────────────────

  /// Fetch + reduce a folder's current state by its id.
  Future<FolderState> browse(String folderId) async {
    final ks = await _currentKeyset(folderId);
    final ops = await query(NostrFilter(
        kinds: [kKindFolderOp],
        tags: {
          kFolderTag: [folderId]
        },
        limit: 2000));
    return reduceFolder(folderId, ks, ops);
  }

  /// Browse a folder and recursively follow its links into a tree (folderId ->
  /// state), depth-limited and cycle-safe.
  Future<Map<String, FolderState>> browseTree(String folderId,
      {int depth = 2}) async {
    final out = <String, FolderState>{};
    Future<void> walk(String id, int d) async {
      if (d < 0 || out.containsKey(id)) return;
      final st = await browse(id);
      out[id] = st;
      for (final l in st.linkList) {
        await walk(l.folderId, d - 1);
      }
    }

    await walk(folderId, depth);
    return out;
  }

  /// Folders this device owns (has the master key for).
  List<FolderKey> ownedFolders() => keystore.all();
}
