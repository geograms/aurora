import 'dart:convert';

import 'dart:async';

import 'package:reticulum/src/services/social/node_profile.dart';
import 'package:reticulum/src/util/rate_ring.dart';
import 'package:reticulum/src/services/social/relay_role.dart';

import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../log_service.dart';
import '../notification_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'package:reticulum/src/util/media_archive.dart';

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

  // ── The requests-per-hour ring ─────────────────────────────────────────────
  //
  // The counters upstream are lifetime totals; this samples their DELTA once a
  // minute into hourly buckets and persists the ring, so the dashboard has a
  // shape and survives a restart. One subtraction and (at most) one pref write
  // per minute — nowhere near any hot path.
  RateRing? _queryRing;
  int _lastQueryTotal = 0;
  Timer? _sampler;

  // The Archiver's two: what other people ASKED for, and what it cost the
  // uplink to give it to them.
  RateRing? _reqRing;
  RateRing? _bwRing;
  int _lastReqTotal = 0;
  int _lastBwTotal = 0;

  RateRing get queryRing {
    if (_queryRing == null) {
      _queryRing = RateRing.decode(
          PreferencesService.instanceSync?.indexerQueryRing ?? '');
      _lastQueryTotal = _rns.queryTotals;
      _sampler ??= Timer.periodic(const Duration(minutes: 1), (_) => _sample());
    }
    return _queryRing!;
  }

  /// The serve rings. Lazily restored from prefs on first read, then advanced by
  /// the same one-minute sampler that feeds the Indexer's.
  ({RateRing req, RateRing bw}) get serveRings {
    if (_reqRing == null || _bwRing == null) {
      final p = PreferencesService.instanceSync;
      _reqRing = RateRing.decode(p?.archiveReqRing ?? '');
      _bwRing = RateRing.decode(p?.archiveBwRing ?? '');
      final q = _rns.serveQuota;
      _lastReqTotal = q?.requestsServedTotal ?? 0;
      _lastBwTotal = q?.bytesServedTotal ?? 0;
      _sampler ??= Timer.periodic(const Duration(minutes: 1), (_) => _sample());
    }
    return (req: _reqRing!, bw: _bwRing!);
  }

  void _sample() {
    final p = PreferencesService.instanceSync;

    final ring = _queryRing;
    if (ring != null) {
      final total = _rns.queryTotals;
      final delta = total - _lastQueryTotal;
      _lastQueryTotal = total;
      if (delta > 0) ring.add(delta);
      // Persist at most once a minute — the encode is a short string either way.
      p?.indexerQueryRing = ring.encode();
    }

    final q = _rns.serveQuota;
    final req = _reqRing;
    final bw = _bwRing;
    if (q != null && req != null && bw != null) {
      final rDelta = q.requestsServedTotal - _lastReqTotal;
      final bDelta = q.bytesServedTotal - _lastBwTotal;
      _lastReqTotal = q.requestsServedTotal;
      _lastBwTotal = q.bytesServedTotal;
      if (rDelta > 0) req.add(rDelta);
      if (bDelta > 0) bw.add(bDelta);
      p?.archiveReqRing = req.encode();
      p?.archiveBwRing = bw.encode();
    }
  }

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

      // The shape, not just the size: is the offer being USED?
      'queriesLastHour': queryRing.lastHour,
      'queriesAvgPerHour':
          double.parse(queryRing.avgPerHour(window: 24).toStringAsFixed(1)),
      'querySpark': queryRing.series(),
      'syncExchanges': PointerSyncService.instance.exchanges,
      'syncApplied': PointerSyncService.instance.totalApplied,
      'syncRemoved': PointerSyncService.instance.totalRemoved,
      'lastSyncMs': PointerSyncService.instance.lastSyncMs,
      'topics': p?.indexerTopics ?? const <String>[],
      // The same list as a plain CSV, because the wapp seeds a TEXT FIELD with
      // it — and a text field holding "[]" is a bug wearing quotes.
      'topicsCsv': (p?.indexerTopics ?? const <String>[]).join(', '),
      'wideActive': role?.wide ?? false,

      // The network as NUMBERS. Individual peers are not listed anywhere —
      // there could be millions, and a list of them tells the owner nothing a
      // count cannot.
      'indexersKnown': _rns.relayDirectory.indexers().length,
      'peersKnown': _rns.relayDirectory.entries().length,

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
      case 'topics':
        _rns.setIndexerTopics(
            value.isEmpty ? const [] : value.split(','));
        return 0;
      default:
        return -1;
    }
  }

  /// Previewed maintenance TILES for the dashboard's stats grid: each says
  /// exactly what it would remove, and only offers that would remove SOMETHING
  /// appear. Tapping a tile runs [nodeSweep] with the same id — what the person
  /// saw is what runs. (Not a people list: a people field hijacks its whole
  /// screen, and maintenance belongs on the dashboard, not behind a tab.)
  String maintJson() {
    final dht = _rns.dhtNode;
    final tiles = <Map<String, dynamic>>[];
    if (dht != null) {
      final ages = dht.ageBuckets();
      tiles.add({
        'id': '#ages',
        'label': 'Pointer ages',
        'value': '${ages.h1 + ages.d1} fresh',
        'hint': '${ages.d7} under a week · ${ages.older} older — where the map '
            'came from.',
      });
      void offer(String id, String label, String why, int n) {
        if (n <= 0) return;
        tiles.add({
          'id': id,
          'label': label,
          'value': '−$n',
          'unit': 'pointers',
          'hint': '$why Tap to run exactly this.',
          'tap': true,
          'alert': true,
        });
      }

      offer(
        'sweep:old7d',
        'Drop older than 7 days',
        'Providers republish every 30 minutes; a week of silence is an answer.',
        _rns.sweepPointersOlderThan(const Duration(days: 7), dryRun: true),
      );
      offer(
        'sweep:old30d',
        'Drop older than 30 days',
        'The conservative sweep: only what has been dead for a month.',
        _rns.sweepPointersOlderThan(const Duration(days: 30), dryRun: true),
      );
    }
    if (tiles.length <= 1) {
      tiles.add({
        'id': '#none',
        'label': 'Clean up',
        'value': 'Nothing to do',
        'hint': 'Every pointer held is fresh.',
      });
    }
    return jsonEncode(tiles);
  }

  /// Run the sweep the row previewed.  /// Run the sweep the row previewed. Returns pointers removed, -1 on error.
  int nodeSweep(String id) {
    switch (id) {
      case 'sweep:old7d':
        return _rns.sweepPointersOlderThan(const Duration(days: 7));
      case 'sweep:old30d':
        return _rns.sweepPointersOlderThan(const Duration(days: 30));
      default:
        if (id.startsWith('provider:')) {
          final pub = id.substring('provider:'.length);
          if (pub.length == 128) return _rns.sweepProviderPointers(pub);
        }
        return -1;
    }
  }

  // ── Archiver ──────────────────────────────────────────────────────────────

  /// The whole contract, in the numbers the owner chose.
  String archiveStatusJson() {
    final p = PreferencesService.instanceSync;
    final policy = ArchiverService.instance.policy;
    final archive = sharedMediaArchive();
    final st = archive?.hostedStats();

    final quotaGb = p?.archiveQuotaGb ?? 0;
    final quotaBytes = quotaGb * 1024 * 1024 * 1024;
    final used = st?.totalBytes ?? 0;

    return jsonEncode({
      'quotaGb': quotaGb,
      'archiving': policy.isArchiving,
      'usedBytes': used,
      'strangerBytes': st?.strangerBytes ?? 0,
      'items': st?.totalItems ?? 0,

      // The dashboard's numbers: how full, how much of it anyone ever wanted,
      // and how much could be reclaimed right now.
      'usedText': _size(used),
      'quotaText': quotaGb == 0 ? 'off' : '$quotaGb GB',
      'fullFrac': quotaBytes == 0
          ? 0.0
          : double.parse((used / quotaBytes).clamp(0.0, 1.0).toStringAsFixed(3)),
      'servedItems': st?.servedItems ?? 0,

      // The last 48 hours: what people asked for, and what it cost the uplink.
      // Bandwidth is graphed in kB per hour — bytes make a sparkline of
      // meaningless magnitudes.
      'reqLastHour': serveRings.req.lastHour,
      'reqAvgPerHour':
          double.parse(serveRings.req.avgPerHour(window: 24).toStringAsFixed(1)),
      'reqSpark': serveRings.req.series(),
      'bwLastHourText': _size(serveRings.bw.lastHour),
      'bwPerHourText': _size(serveRings.bw.avgPerHour(window: 24).round()),
      'bwSpark': [
        for (final v in serveRings.bw.series()) (v / 1024).round(),
      ],
      // What the Free-space button would ACTUALLY give back — everything held
      // for other people. Previewing a different sweep than the button runs is
      // how a UI ends up lying to the person about to press it.
      'freeableBytes': archive?.previewSweep(const HostedSweep.all()).bytes ?? 0,
      'freeableText':
          _size(archive?.previewSweep(const HostedSweep.all()).bytes ?? 0),
      'followed': p?.archiveFollowed ?? true,
      'topics': p?.archiveTopics ?? const <String>[],
      'fromLan': p?.archiveFromLan ?? true,
      'fromBluetooth': p?.archiveFromBluetooth ?? true,
      'fromRadio': p?.archiveFromRadio ?? true,
      'fromWifiDirect': p?.archiveFromWifiDirect ?? true,
      'mirrorSmall': p?.archiveMirrorSmall ?? true,
      'fromNearby': (p?.archiveFromLan ?? true) ||
          (p?.archiveFromBluetooth ?? true) ||
          (p?.archiveFromRadio ?? true),
      // The deposit gate now knows which interface a peer arrived on, so the
      // direct-link offer actually fires: a peer that reached us over the LAN,
      // Bluetooth or LoRa is recognised as one with no route to anywhere else.
      'directLinksActive': true,
    });
  }

  /// Where the space went — statistics, not a list.
  ///
  /// An archive is expected to hold hundreds of thousands of blobs. A user
  /// scrolling that list learns nothing and can do nothing about it. What they
  /// need is: how full am I, whose is it, is any of it even being used, and how
  /// do I get a gigabyte back. So this is the breakdown, and [archiveSweep] is
  /// the way out.
  String archiveItemsJson() {
    final archive = sharedMediaArchive();
    if (archive == null) return '[]';
    final st = archive.hostedStats();
    final now = DateTime.now().millisecondsSinceEpoch;

    final sections = <Map<String, dynamic>>[];

    // 1. Where the space went.
    sections.add({
      'title': 'Space',
      'items': [
        {
          'id': '#total',
          'title': '${_size(st.totalBytes)} across ${st.totalItems} files',
          'subtitle': st.oldestMs > 0
              ? 'Oldest kept ${_ago(now - st.oldestMs)}'
              : 'Nothing held for anybody yet',
          'online': st.totalItems > 0,
        },
        {
          'id': '#strangers',
          'title': '${_size(st.strangerBytes)} · strangers',
          'subtitle': '${st.strangerItems} files. The evictable slice — and the '
              'only thing a cleanup here will ever touch.',
          'online': false,
        },
        {
          'id': '#followed',
          'title': '${_size(st.followedBytes)} · people you follow',
          'subtitle': '${st.followedItems} files. Redundancy for the accounts '
              'you care about.',
          'online': true,
        },
        {
          'id': '#pinned',
          'title': '${_size(st.pinnedBytes)} · kept on purpose',
          'subtitle': '${st.pinnedItems} files. You asked for these; no cleanup '
              'will ever remove them.',
          'online': true,
        },
        {
          'id': '#served',
          'title': '${st.servedItems} of ${st.totalItems} ever fetched',
          'subtitle': st.servedItems == 0 && st.totalItems > 0
              ? 'Nobody has asked for any of it yet. Normal in a new archive; '
                  'dead weight in an old one.'
              : 'The rest is dead weight, and cleanup starts there.',
          'online': st.servedItems > 0,
        },
      ],
    });

    // 2. Whose is it. The row a person can actually act on.
    final byOrigin = archive.hostedByOrigin(limit: 8);
    if (byOrigin.isNotEmpty) {
      sections.add({
        'title': 'Depositors',
        'items': [
          for (final o in byOrigin)
            {
              'id': 'origin:${o.originPub}',
              'title': '${_size(o.bytes)} · ${o.items} file'
                  '${o.items == 1 ? '' : 's'}',
              'subtitle': '${o.originPub.isEmpty ? 'unknown depositor' : o.originPub.substring(0, 16)} — tap to evict everything they put here',
              'online': false,
            }
        ],
      });
    }

    // 3. The way out. Every option previews what it would free BEFORE it does
    //    it: a cleanup tool that cannot tell you what it is about to delete is
    //    not a tool, it is a gamble.
    final sweeps = <Map<String, dynamic>>[];
    void offer(String id, String label, String why, ({int bytes, int items}) p) {
      if (p.items == 0) return;
      sweeps.add({
        'id': id,
        'title': '$label — frees ${_size(p.bytes)} (${p.items} files)',
        'subtitle': why,
        'online': false,
      });
    }

    offer(
      'sweep:neverServed',
      'Never asked for',
      'Stranger files nobody has ever fetched from you. Dead weight by '
          'definition.',
      archive.previewSweep(const HostedSweep.neverServed()),
    );
    offer(
      'sweep:old90',
      'Strangers over 90 days',
      'Kept long enough to have been useful. Nobody came.',
      archive.previewSweep(const HostedSweep.olderThan(90 * 24 * 3600 * 1000)),
    );
    offer(
      'sweep:strangers',
      'All strangers',
      'Keeps the people you follow, and everything you asked to keep.',
      archive.previewSweep(const HostedSweep.strangers()),
    );
    offer(
      'sweep:free1g',
      'Free up to 1 GB',
      'Oldest strangers first. It stops when it has enough — and never reaches '
          'into the media of people you follow.',
      archive.previewSweep(const HostedSweep.freeBytes(1 << 30)),
    );

    sections.add({
      'title': 'Clean up',
      'items': sweeps.isEmpty
          ? [
              {
                'id': '#clean',
                'title': 'Nothing to reclaim',
                'subtitle': 'Everything here is either yours or belongs to '
                    'somebody you follow — a cleanup would have nothing to take.',
                'online': true,
              }
            ]
          : sweeps,
    });

    return jsonEncode(sections);
  }

  /// Run a cleanup. The id comes straight from the row the user tapped, so what
  /// they saw previewed is exactly what runs.
  int archiveSweep(String id) {
    final archive = sharedMediaArchive();
    if (archive == null) return -1;

    HostedSweep? sweep;
    if (id == 'sweep:all') {
      sweep = const HostedSweep.all();
    } else if (id == 'sweep:neverServed') {
      sweep = const HostedSweep.neverServed();
    } else if (id == 'sweep:old90') {
      sweep = const HostedSweep.olderThan(90 * 24 * 3600 * 1000);
    } else if (id == 'sweep:strangers') {
      sweep = const HostedSweep.strangers();
    } else if (id == 'sweep:free1g') {
      sweep = const HostedSweep.freeBytes(1 << 30);
    } else if (id.startsWith('origin:')) {
      final pub = id.substring('origin:'.length);
      if (pub.isEmpty) return -1;
      sweep = HostedSweep.byOrigin(pub);
    }
    if (sweep == null) return -1;

    final r = archive.sweepHosted(sweep);
    LogService.instance.add(
        'archive: cleanup $id freed ${_size(r.bytes)} (${r.items} files)');

    // Say it happened. A destructive action that reports nothing leaves the
    // person unsure whether it ran — and "nothing to delete" is a real,
    // legitimate outcome that must not look like a broken button.
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: r.items == 0
          ? 'Nothing to free'
          : 'Freed ${_size(r.bytes)}',
      body: r.items == 0
          ? 'This device is holding nothing for other people.'
          : '${r.items} file${r.items == 1 ? '' : 's'} kept for other people '
              'were deleted. Your own files were not touched.',
      source: 'wapp:archiver',
      scope: NotificationScope.app,
    ));
    return r.items;
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
      case 'fromNearby':
        // One switch for "peers with nowhere else to go" — LAN, Bluetooth,
        // LoRa, Wi-Fi Direct. A person does not think in transports.
        final v = on();
        p.archiveFromLan = v;
        p.archiveFromBluetooth = v;
        p.archiveFromRadio = v;
        p.archiveFromWifiDirect = v;
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
