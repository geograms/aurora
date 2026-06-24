/*
 * FolderRelay — peer-to-peer folder discovery by key, no indexer required.
 *
 * A folder's state is signed NOSTR events. Discovery reuses the SAME mechanism
 * Aurora uses to find files by sha256: every device that holds a folder publishes
 * a DHT provider record keyed by the folder's public key; a peer with only that
 * key resolves providers via the DHT and queries them directly for the events.
 * Anyone who browses caches the events locally and auto-seeds, so any device can
 * serve a folder it has seen.
 *
 * Transport-agnostic: the owner injects how to publish a provider, resolve
 * providers, and query a provider's relay — so rns_service and headless tests
 * share this logic.
 */
import 'dart:typed_data';

import '../reticulum/rns_identity.dart';
import '../social/relay_event_store.dart' show RelayEventStore, NostrFilter;
import '../../util/nostr_event.dart';

typedef ProviderPublish = Future<void> Function(Uint8List key32);
typedef ProviderResolve = Future<List<RnsIdentity>> Function(Uint8List key32);
typedef ProviderQuery = Future<List<NostrEvent>> Function(
    RnsIdentity provider, NostrFilter filter);

class FolderRelay {
  final RelayEventStore store;
  final ProviderPublish publishProvider;
  final ProviderResolve resolveProviders;
  final ProviderQuery queryProvider;
  final int maxProviders;
  final void Function(String msg)? log;

  FolderRelay({
    required this.store,
    required this.publishProvider,
    required this.resolveProviders,
    required this.queryProvider,
    this.maxProviders = 3,
    this.log,
  });

  /// The query callback for FolderService: resolve providers for the folder this
  /// filter targets, pull their matching events into the local store, and answer
  /// from the (now-merged) local store. Falls back to local-only on any failure.
  Future<List<NostrEvent>> query(NostrFilter f) async {
    final key = _keyOf(f);
    if (key != null) {
      try {
        final providers = await resolveProviders(key);
        // Query providers CONCURRENTLY, not one-after-another. A single stale or
        // offline provider (e.g. a node that used to host this folder but has
        // since gone away) otherwise blocks discovery for its whole relay-query
        // timeout, and a few stacked serially run to minutes — the cause of the
        // multi-minute "check for updates" hang. In parallel the slowest dead
        // provider costs one timeout, not the sum, and a live holder's events
        // still merge in. Each provider is isolated so one failure can't sink
        // the others.
        await Future.wait(providers.take(maxProviders).map((p) async {
          try {
            final events = await queryProvider(p, f);
            for (final e in events) {
              store.put(e); // verifies + dedups + applies replaceable
            }
          } catch (_) {/* skip an unreachable provider; others still answer */}
        }));
      } catch (e) {
        log?.call('folder discovery query failed: $e');
      }
    }
    return store.query(f);
  }

  /// Advertise this node as a provider of [folderId] (hex) in the DHT.
  Future<void> publish(String folderId) async {
    final key = _idBytes(folderId);
    if (key != null) await publishProvider(key);
  }

  /// The folderId a filter targets: authors[0] (key-set) or the 'd' tag (ops).
  static Uint8List? _keyOf(NostrFilter f) {
    if (f.authors != null && f.authors!.isNotEmpty) {
      return _idBytes(f.authors!.first);
    }
    final d = f.tags?['d'];
    if (d != null && d.isNotEmpty) return _idBytes(d.first);
    return null;
  }

  static Uint8List? _idBytes(String hex) {
    if (hex.length != 64) return null;
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }
}
