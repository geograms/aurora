/*
 * Folder event model — IPNS-like mutable folders as signed NOSTR events on the
 * relay (see plan: mutable folders over the NOSTR relay).
 *
 * A folder is a secp256k1 identity. folderId = the master public key (hex,
 * x-only); its npub is the permanent shareable address. Two event kinds:
 *
 *   KEYSET (kKindFolderKeyset, NIP-33 parameterized-replaceable, 'd' = folderId)
 *     signed ONLY by the master. content = {"admins":[{p,role,a,r?}]}. The latest
 *     master-signed keyset is authoritative (the relay keeps only the newest per
 *     pubkey+kind+d), so only the owner controls who may write.
 *
 *   OP (kKindFolderOp, regular/non-replaceable, tagged 'd' = folderId) signed by
 *     the master OR an authorized admin. content = one operation:
 *       {"op":"addFile","x":<sha256hex>,"name":..,"desc":..,"mime":..,"size":..}
 *       {"op":"rmFile","x":<sha256hex>}
 *       {"op":"setMeta","name":..,"desc":..}      (folder name/description)
 *       {"op":"link","f":<folderId>,"name":..}    (link another folder)
 *       {"op":"unlink","f":<folderId>}
 *
 * Pure/headless: only nostr_event + nostr_crypto + dart:convert.
 */
import 'dart:convert';

import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';

/// NIP-33 parameterized-replaceable: the master-signed admin key-set.
const int kKindFolderKeyset = 30564;

/// Regular (non-replaceable) folder mutation; the full log is retained.
const int kKindFolderOp = 1064;

/// The 'd' tag name carries the folderId on both kinds.
const String kFolderTag = 'd';

class FolderRole {
  static const String moderator = 'moderator';
  static const String contributor = 'contributor';
}

/// An authorized admin in the key-set. [addedAt]/[revokedAt] are unix seconds;
/// an edit by this admin counts only if addedAt <= ts < (revokedAt ?? inf).
class AdminEntry {
  final String pubkey; // hex x-only
  final String role;
  final int addedAt;
  final int? revokedAt;
  const AdminEntry(this.pubkey, this.role, this.addedAt, [this.revokedAt]);

  bool authorizedAt(int ts) =>
      ts >= addedAt && (revokedAt == null || ts < revokedAt!);

  Map<String, dynamic> toJson() => {
        'p': pubkey,
        'role': role,
        'a': addedAt,
        if (revokedAt != null) 'r': revokedAt,
      };

  static AdminEntry? fromJson(Object? o) {
    if (o is! Map) return null;
    final p = o['p'];
    final a = o['a'];
    if (p is! String || a is! int) return null;
    return AdminEntry(p, (o['role'] ?? FolderRole.contributor).toString(), a,
        o['r'] is int ? o['r'] as int : null);
  }
}

class FileEntry {
  final String sha; // sha256 hex
  final String? name;
  final String? desc;
  final String? mime;
  final int? size;
  final int? ts; // file date (unix seconds): mtime if known, else when added
  const FileEntry(this.sha,
      {this.name, this.desc, this.mime, this.size, this.ts});

  Map<String, dynamic> toJson() => {
        'x': sha,
        if (name != null) 'name': name,
        if (desc != null) 'desc': desc,
        if (mime != null) 'mime': mime,
        if (size != null) 'size': size,
        if (ts != null) 'ts': ts,
      };
}

class LinkEntry {
  final String folderId; // target folder's id (hex master pubkey)
  final String? name;
  const LinkEntry(this.folderId, {this.name});

  Map<String, dynamic> toJson() =>
      {'f': folderId, if (name != null) 'name': name};
}

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Derive a folderId (hex pubkey) from a master private key (hex).
String folderIdFromPriv(String masterPrivHex) =>
    NostrCrypto.derivePublicKey(masterPrivHex);

/// Build the master-signed KEYSET event listing [admins]. Must be signed with
/// the master key (its pubkey == folderId).
NostrEvent buildKeyset(String masterPrivHex, List<AdminEntry> admins,
    {int? createdAt}) {
  final folderId = folderIdFromPriv(masterPrivHex);
  final e = NostrEvent(
    pubkey: folderId,
    createdAt: createdAt ?? _nowSec(),
    kind: kKindFolderKeyset,
    tags: [
      [kFolderTag, folderId]
    ],
    content: jsonEncode({'admins': [for (final a in admins) a.toJson()]}),
  );
  e.sign(masterPrivHex);
  return e;
}

/// Build a folder OP event signed by [authorPrivHex] (master or an admin).
NostrEvent buildOp(String authorPrivHex, String folderId,
    Map<String, dynamic> op,
    {int? createdAt}) {
  final e = NostrEvent(
    pubkey: NostrCrypto.derivePublicKey(authorPrivHex),
    createdAt: createdAt ?? _nowSec(),
    kind: kKindFolderOp,
    tags: [
      [kFolderTag, folderId]
    ],
    content: jsonEncode(op),
  );
  e.sign(authorPrivHex);
  return e;
}

// ── Operation payload builders ──────────────────────────────────────────────

Map<String, dynamic> opAddFile(String shaHex,
        {String? name, String? desc, String? mime, int? size, int? ts}) =>
    {
      'op': 'addFile',
      'x': shaHex,
      'name': ?name,
      'desc': ?desc,
      'mime': ?mime,
      'size': ?size,
      'ts': ?ts,
    };

Map<String, dynamic> opRmFile(String shaHex, {String? name}) =>
    {'op': 'rmFile', 'x': shaHex, 'n': ?name};

Map<String, dynamic> opSetMeta(
        {String? name, String? desc, String? tags, String? owner}) =>
    {'op': 'setMeta', 'name': ?name, 'desc': ?desc, 'tags': ?tags, 'owner': ?owner};

Map<String, dynamic> opLink(String folderId, {String? name}) =>
    {'op': 'link', 'f': folderId, 'name': ?name};

Map<String, dynamic> opUnlink(String folderId) =>
    {'op': 'unlink', 'f': folderId};
