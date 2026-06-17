/*
 * FolderState + reducer — compute a mutable folder's current contents from its
 * signed events (the master KEYSET + the OP edit-log). This is the heart of the
 * IPNS-like folder: anyone holding the folderId fetches these events from the
 * relay and reduces them to the same state.
 *
 * Authorization: an OP is applied only if its signature verifies AND its author
 * was authorized at the op's created_at — the master (author == folderId) always,
 * or an admin whose key-set entry covers that timestamp (addedAt <= ts <
 * revokedAt). So revoking an admin stops only future edits; their earlier,
 * legitimately-signed edits remain.
 *
 * Conflict resolution: ops apply in created_at order (ties broken by event id);
 * files are keyed by sha (addFile upserts, rmFile deletes), folder name/desc are
 * last-writer-wins, links are keyed by target folderId.
 */
import 'dart:convert';

import '../../util/nostr_event.dart';
import 'folder_event.dart';

class FolderState {
  final String folderId;
  String? name;
  String? desc;
  final Map<String, FileEntry> files = {}; // sha -> entry
  final Map<String, LinkEntry> links = {}; // target folderId -> entry
  List<AdminEntry> admins = const [];

  FolderState(this.folderId);

  List<FileEntry> get fileList => files.values.toList();
  List<LinkEntry> get linkList => links.values.toList();

  Map<String, dynamic> toJson() => {
        'folderId': folderId,
        if (name != null) 'name': name,
        if (desc != null) 'desc': desc,
        'files': [for (final f in fileList) f.toJson()],
        'links': [for (final l in linkList) l.toJson()],
        'admins': [for (final a in admins) a.toJson()],
      };
}

/// Parse the admin list from a master-signed KEYSET event, or empty if the
/// event is missing/invalid/not signed by the folder master.
List<AdminEntry> _adminsFromKeyset(String folderId, NostrEvent? keyset) {
  if (keyset == null) return const [];
  if (keyset.kind != kKindFolderKeyset) return const [];
  if (keyset.pubkey != folderId) return const []; // only the master defines it
  if (!keyset.verify()) return const [];
  try {
    final m = jsonDecode(keyset.content);
    if (m is! Map) return const [];
    final list = m['admins'];
    if (list is! List) return const [];
    return [
      for (final e in list) ?AdminEntry.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// Reduce a folder's [keyset] + [ops] into its current [FolderState].
FolderState reduceFolder(
    String folderId, NostrEvent? keyset, List<NostrEvent> ops) {
  final state = FolderState(folderId);
  final admins = _adminsFromKeyset(folderId, keyset);
  state.admins = admins;

  bool authorized(String pubkey, int ts) {
    if (pubkey == folderId) return true; // master, always
    for (final a in admins) {
      if (a.pubkey == pubkey && a.authorizedAt(ts)) return true;
    }
    return false;
  }

  // Stable order: oldest first, ties broken by event id.
  final ordered = [...ops]..sort((a, b) {
      final d = a.createdAt.compareTo(b.createdAt);
      if (d != 0) return d;
      return (a.id ?? '').compareTo(b.id ?? '');
    });

  for (final op in ordered) {
    if (op.kind != kKindFolderOp) continue;
    if (!_hasFolderTag(op, folderId)) continue;
    if (!authorized(op.pubkey, op.createdAt)) continue;
    if (!op.verify()) continue;
    Object? payload;
    try {
      payload = jsonDecode(op.content);
    } catch (_) {
      continue;
    }
    if (payload is! Map) continue;
    _apply(state, payload);
  }
  return state;
}

bool _hasFolderTag(NostrEvent e, String folderId) {
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == kFolderTag && t[1] == folderId) return true;
  }
  return false;
}

void _apply(FolderState s, Map payload) {
  switch (payload['op']) {
    case 'addFile':
      final x = payload['x'];
      if (x is String && x.isNotEmpty) {
        s.files[x] = FileEntry(
          x,
          name: payload['name'] as String?,
          desc: payload['desc'] as String?,
          mime: payload['mime'] as String?,
          size: payload['size'] is int ? payload['size'] as int : null,
        );
      }
      break;
    case 'rmFile':
      final x = payload['x'];
      if (x is String) s.files.remove(x);
      break;
    case 'setMeta':
      if (payload.containsKey('name')) s.name = payload['name'] as String?;
      if (payload.containsKey('desc')) s.desc = payload['desc'] as String?;
      break;
    case 'link':
      final f = payload['f'];
      if (f is String && f.isNotEmpty) {
        s.links[f] = LinkEntry(f, name: payload['name'] as String?);
      }
      break;
    case 'unlink':
      final f = payload['f'];
      if (f is String) s.links.remove(f);
      break;
    default:
      break;
  }
}
