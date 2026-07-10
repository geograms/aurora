import 'package:flutter/foundation.dart';

/// Per-wapp unread counts that drive launcher badges. Counts are session-scoped
/// and in-memory. Base keys are `wappId`; intent-specific counts use
/// `wappId#intent` so host icons can distinguish "messages" from "chat" even
/// when one wapp provides both views.
class WappUnreadService {
  WappUnreadService._();
  static final WappUnreadService instance = WappUnreadService._();

  /// composite key -> unread count (entries with 0 are removed).
  final ValueNotifier<Map<String, int>> counts =
      ValueNotifier<Map<String, int>>(const {});

  String _key(String wappId, String? intent) {
    final cleanIntent = intent?.trim().toLowerCase();
    if (cleanIntent == null || cleanIntent.isEmpty) return wappId;
    return '$wappId#$cleanIntent';
  }

  int countFor(String wappId, {String? intent}) =>
      counts.value[_key(wappId, intent)] ?? 0;

  int totalFor(String wappId) {
    var total = counts.value[wappId] ?? 0;
    final prefix = '$wappId#';
    for (final e in counts.value.entries) {
      if (e.key.startsWith(prefix)) total += e.value;
    }
    return total;
  }

  /// Set the authoritative count for [wappId]; 0/negative clears it.
  void setCount(String wappId, int n, {String? intent}) {
    final key = _key(wappId, intent);
    if ((counts.value[key] ?? 0) == (n > 0 ? n : 0)) return;
    final m = Map<String, int>.from(counts.value);
    if (n > 0) {
      m[key] = n;
    } else {
      m.remove(key);
    }
    counts.value = m;
  }

  void add(String wappId, int n, {String? intent}) =>
      setCount(wappId, countFor(wappId, intent: intent) + n, intent: intent);

  void clear(String wappId, {String? intent}) =>
      setCount(wappId, 0, intent: intent);

  void clearAll(String wappId) {
    final prefix = '$wappId#';
    final m = Map<String, int>.from(counts.value);
    final before = m.length;
    m.removeWhere((key, _) => key == wappId || key.startsWith(prefix));
    if (m.length == before) return;
    counts.value = m;
  }
}
