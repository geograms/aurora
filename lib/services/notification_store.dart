import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import 'event_bus.dart';
import 'notification_service.dart';

class StoredNotification {
  final String id;
  final NotificationLevel level;
  final String title;
  final String? body;
  final String source;
  final DateTime timestamp;

  const StoredNotification({
    required this.id,
    required this.level,
    required this.title,
    this.body,
    required this.source,
    required this.timestamp,
  });

  factory StoredNotification.fromJson(Map<String, dynamic> json) {
    return StoredNotification(
      id: (json['id'] ?? '').toString(),
      level: _levelFromString((json['level'] ?? 'info').toString()),
      title: (json['title'] ?? '').toString(),
      body: json['body']?.toString(),
      source: (json['source'] ?? '').toString(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['timestamp'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  factory StoredNotification.fromNotification(GeogramNotification n) {
    final ts = n.timestamp;
    return StoredNotification(
      id: '${ts.microsecondsSinceEpoch}:${n.source}',
      level: n.level,
      title: n.title,
      body: n.body,
      source: n.source,
      timestamp: ts,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'level': level.name,
    'title': title,
    if (body != null) 'body': body,
    'source': source,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };
}

NotificationLevel _levelFromString(String raw) {
  return switch (raw.toLowerCase()) {
    'success' => NotificationLevel.success,
    'warning' || 'warn' => NotificationLevel.warning,
    'error' || 'err' => NotificationLevel.error,
    _ => NotificationLevel.info,
  };
}

class NotificationStore {
  NotificationStore._();
  static final NotificationStore instance = NotificationStore._();

  static const int maxItems = 300;
  static const String _itemsFile = 'notifications/history.jsonl';
  static const String _seenFile = 'notifications/seen_ms.txt';

  final ValueNotifier<List<StoredNotification>> items =
      ValueNotifier<List<StoredNotification>>(const []);
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  EventSubscription<NotificationShownEvent>? _sub;
  bool _initialised = false;
  int _seenMs = 0;

  void init() {
    if (_initialised) return;
    _initialised = true;
    _sub = EventBus().on<NotificationShownEvent>((e) {
      unawaited(record(e.notification).catchError((_) {}));
    });
    ProfileService.instance.activeProfileNotifier.addListener(_reload);
    unawaited(_load());
  }

  Future<void> record(GeogramNotification n) async {
    final next = [
      StoredNotification.fromNotification(n),
      ...items.value,
    ].take(maxItems).toList(growable: false);
    items.value = next;
    _recomputeUnread();
    try {
      await _persistItems(next);
    } catch (_) {}
  }

  Future<void> markAllSeen() async {
    _seenMs = DateTime.now().millisecondsSinceEpoch;
    unreadCount.value = 0;
    try {
      final root = activeProfileRoot();
      await root.createDirectory('notifications');
      await root.writeString(_seenFile, '$_seenMs');
    } catch (_) {}
  }

  Future<void> clear() async {
    items.value = const [];
    unreadCount.value = 0;
    try {
      final root = activeProfileRoot();
      await root.delete(_itemsFile);
      await root.delete(_seenFile);
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    _sub?.cancel();
    _sub = null;
    _initialised = false;
    _seenMs = 0;
    items.value = const [];
    unreadCount.value = 0;
    ProfileService.instance.activeProfileNotifier.removeListener(_reload);
  }

  void _reload() {
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final root = activeProfileRoot();
      final seenRaw = await root.readString(_seenFile);
      _seenMs = int.tryParse((seenRaw ?? '').trim()) ?? 0;
      final raw = await root.readString(_itemsFile);
      if (raw == null || raw.trim().isEmpty) {
        items.value = const [];
        unreadCount.value = 0;
        return;
      }
      final loaded = <StoredNotification>[];
      for (final line in const LineSplitter().convert(raw)) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            loaded.add(StoredNotification.fromJson(decoded));
          }
        } catch (_) {}
      }
      loaded.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      items.value = loaded.take(maxItems).toList(growable: false);
      _recomputeUnread();
    } catch (_) {
      items.value = const [];
      unreadCount.value = 0;
    }
  }

  Future<void> _persistItems(List<StoredNotification> list) async {
    final root = activeProfileRoot();
    await root.createDirectory('notifications');
    await root.writeString(
      _itemsFile,
      list.map((n) => jsonEncode(n.toJson())).join('\n'),
    );
  }

  void _recomputeUnread() {
    unreadCount.value = items.value
        .where((n) => n.timestamp.millisecondsSinceEpoch > _seenMs)
        .length;
  }
}
