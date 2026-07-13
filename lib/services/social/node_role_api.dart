import 'dart:convert';

import 'package:reticulum/src/services/social/node_profile.dart';
import 'package:reticulum/src/services/social/relay_role.dart';

import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'archiver_service.dart';
import 'node_profile_service.dart';
import 'pointer_sync_service.dart';

/// The host side of the **Indexer** and **Archiver** wapps (docs/NOSTR.md).
///
/// Two roles a person GRANTS, INSPECTS and REVOKES — which is the whole reason
/// these exist. Until now the role was inferred from the charger and the WiFi:
/// a decent default and a bad only-option, because the old phone in a drawer had
/// no way to say "yes, use this" and the metered home line had no way to say
/// "no, don't".
///
/// Everything here is read-mostly and cheap: counters the node already keeps, a
/// preferences read, and an inventory query the archive already answers. No
/// crypto, no network, nothing that could stall the UI isolate.
class NodeRoleApi {
  NodeRoleApi._();
  static final NodeRoleApi instance = NodeRoleApi._();

  RnsService get _rns => RnsService.instance;

  // ── Indexer ───────────────────────────────────────────────────────────────

  /// What this device is doing for the network, and at whose invitation.
  ///
  /// A role nobody can inspect is a role nobody trusts, so every number a person
  /// might use to judge the offer is here: pointers held, distinct authors
  /// covered, dead pointers pruned, stores refused, and who we sync with.
  String statusJson() {
    final p = PreferencesService.instanceSync;
    final dht = _rns.dhtNode;
    final role = _rns.relayRole?.current;
    final profile = NodeProfileService.instance.build();

    return jsonEncode({
      // What we are, and why.
      'volunteer': p?.indexerVolunteer ?? 'auto',
      'serving': _rns.isIndexer,
      'role': role == null
          ? 'leaf'
          : (role.isIndexer ? 'indexer' : 'leaf'),
      'wide': role?.wide ?? false,
      'uptimeSec': _rns.uptimeSeconds,

      // The pointer map. An Indexer holds ADDRESSES, never other people's posts
      // — the number that matters is how many it can answer for, not how many
      // megabytes it is sitting on.
      'pointers': dht?.storedKeys ?? 0,
      'replicas': dht?.replicasStored ?? 0,
      'demoted': dht?.providersDemoted ?? 0,
      'rejected': dht?.storesRejected ?? 0,
      'authors': _rns.advertisedAuthors.length,
      'logSeq': _rns.pointerLog?.nextSeq ?? 0,
      'logEpoch': _rns.pointerLog?.epoch ?? '',
      'syncPeers': PointerSyncService.instance.peersTracked,

      // The hardware, so the wapp can show a one-line summary and link into
      // Settings → Hardware rather than asking for any of it a second time.
      'power': profile.power.name,
      'uplink': profile.uplink.name,
      'poweredPct': profile.poweredPct,
      'radios': profile.radios.length,
      'gridIndependent': profile.gridIndependent,
      'reachableOffgrid': profile.reachableOffgrid,
    });
  }

  /// The other Indexers this device knows, as people-widget sections: capacity,
  /// uptime, hop distance, and whether we sync with them.
  String peersJson() {
    final entries = _rns.relayDirectory.entries();
    final now = DateTime.now().millisecondsSinceEpoch;

    List<Map<String, dynamic>> rows(bool indexers) => [
          for (final e in entries)
            if (e.announcement.isIndexer == indexers)
              {
                'id': e.idHex.substring(0, 12),
                'title': e.idHex.substring(0, 12).toUpperCase(),
                'subtitle': _describePeer(e, now),
                'online': now - e.lastSeenMs < 3600 * 1000,
              }
        ];

    final ix = rows(true);
    final leaves = rows(false);
    return jsonEncode([
      {
        'title': 'Indexers (${ix.length})',
        'items': ix,
      },
      {
        // Named plainly, because the asymmetry is the design: leaves announce,
        // they get indexed, and they are left alone.
        'title': 'Leaves — announced, indexed, never woken (${leaves.length})',
        'items': leaves,
      },
    ]);
  }

  String _describePeer(RelayEntry e, int nowMs) {
    final a = e.announcement;
    final age = (nowMs - e.lastSeenMs) ~/ 1000;
    final bits = <String>[
      if (a.has(RelayCap.search)) 'search',
      if (a.has(RelayCap.storeForward)) 'store+fwd',
      if (a.wide) 'wide',
      if (a.profile.gridIndependent) a.profile.power.name,
      if (a.profile.uplink != UplinkKind.unknown) a.profile.uplink.name,
      '${e.hops} hop${e.hops == 1 ? '' : 's'}',
      age < 120 ? 'just now' : '${age ~/ 60}m ago',
      if (a.uptimeSeconds > 3600) 'up ${a.uptimeSeconds ~/ 3600}h',
    ];
    return bits.join(' · ');
  }

  /// `key=value` from the wapp. The only knob that matters here: whether the
  /// person is volunteering this device at all.
  int setPref(String kv) {
    final i = kv.indexOf('=');
    if (i <= 0) return -1;
    final key = kv.substring(0, i).trim();
    final value = kv.substring(i + 1).trim();
    final p = PreferencesService.instanceSync;
    if (p == null) return -1;

    switch (key) {
      case 'volunteer':
        // off        — hold nothing, answer nothing. Revoking must be as easy
        //              as granting, or it was never really granted.
        // auto       — serve when plugged in (the old, inferred behaviour)
        // always     — serve regardless, because the owner said so
        if (!const ['off', 'auto', 'always'].contains(value)) return -1;
        p.indexerVolunteer = value;
        p.hostEnabled = value != 'off';
        p.hostCapacityGated = value == 'auto';
        _rns.applyHostingSettings();
        LogService.instance.add('indexer: volunteer=$value');
        return 0;
      default:
        return -1;
    }
  }

  // ── Archiver ──────────────────────────────────────────────────────────────

  /// The whole contract, in the numbers the owner chose.
  String archiveStatusJson() {
    final p = PreferencesService.instanceSync;
    final policy = ArchiverService.instance.policy;
    final archive = sharedMediaArchive();
    final totals = archive?.hostedTotals();

    return jsonEncode({
      'quotaGb': p?.archiveQuotaGb ?? 0,
      'archiving': policy.isArchiving,
      'usedBytes': totals?.totalHostedBytes ?? 0,
      'strangerBytes': totals?.strangerBytes ?? 0,
      'items': archive?.hostedInventory().length ?? 0,
      'followed': p?.archiveFollowed ?? true,
      'topics': p?.archiveTopics ?? const <String>[],
      'fromLan': p?.archiveFromLan ?? true,
      'fromBluetooth': p?.archiveFromBluetooth ?? true,
      'fromRadio': p?.archiveFromRadio ?? true,
      'fromWifiDirect': p?.archiveFromWifiDirect ?? true,
      'mirrorSmall': p?.archiveMirrorSmall ?? true,
      // The deposit gate now knows which interface a peer arrived on, so the
      // direct-link offer actually fires: a peer that reached us over the LAN,
      // Bluetooth or LoRa is recognised as one with no route to anywhere else.
      'directLinksActive': true,
    });
  }

  /// What strangers actually put on this disk. A user who cannot SEE and DELETE
  /// what is being held for others has not consented to anything, so this is the
  /// list, with a Drop on every row.
  String archiveItemsJson() {
    final archive = sharedMediaArchive();
    if (archive == null) return '[]';
    final inv = archive.hostedInventory()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    final now = DateTime.now().millisecondsSinceEpoch;

    return jsonEncode([
      {
        'title': 'Held for others (${inv.length})',
        'items': [
          for (final it in inv.take(200))
            {
              'id': it.sha,
              'title': '${_size(it.bytes)} · ${_tierName(it.tier)}',
              'subtitle': 'kept ${_ago(now - it.receivedAtMs)} · ${it.sha.substring(0, 12)}',
              'online': it.tier < 2,
            }
        ],
      }
    ]);
  }

  /// Drop one blob we were holding for somebody else.
  int archiveDrop(String sha) {
    final archive = sharedMediaArchive();
    if (archive == null || sha.isEmpty) return -1;
    try {
      archive.delete(sha);
      LogService.instance.add('archive: dropped ${sha.substring(0, 12)}');
      return 0;
    } catch (e) {
      LogService.instance.add('archive: drop failed: $e');
      return -1;
    }
  }

  int archiveSetPref(String kv) {
    final i = kv.indexOf('=');
    if (i <= 0) return -1;
    final key = kv.substring(0, i).trim();
    final value = kv.substring(i + 1).trim();
    final p = PreferencesService.instanceSync;
    if (p == null) return -1;

    bool on() => value == '1' || value.toLowerCase() == 'true';

    switch (key) {
      case 'quotaGb':
        final gb = int.tryParse(value);
        if (gb == null || gb < 0 || gb > 4096) return -1;
        p.archiveQuotaGb = gb;
        LogService.instance.add(
            'archive: quota ${gb == 0 ? 'OFF — holding nothing for anybody' : '$gb GB'}');
        return 0;
      case 'followed':
        p.archiveFollowed = on();
        return 0;
      case 'fromLan':
        p.archiveFromLan = on();
        return 0;
      case 'fromBluetooth':
        p.archiveFromBluetooth = on();
        return 0;
      case 'fromRadio':
        p.archiveFromRadio = on();
        return 0;
      case 'fromWifiDirect':
        p.archiveFromWifiDirect = on();
        return 0;
      case 'mirrorSmall':
        p.archiveMirrorSmall = on();
        return 0;
      case 'topics':
        p.archiveTopics = value.isEmpty
            ? const []
            : value.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
        return 0;
      default:
        return -1;
    }
  }

  static String _tierName(int tier) => switch (tier) {
        0 => 'mine',
        1 => 'someone I follow',
        _ => 'a stranger',
      };

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).round()} kB';
    return '$b B';
  }

  static String _ago(int ms) {
    final s = ms ~/ 1000;
    if (s < 3600) return '${s ~/ 60}m ago';
    if (s < 86400) return '${s ~/ 3600}h ago';
    return '${s ~/ 86400}d ago';
  }
}
