import 'package:flutter/foundation.dart';

/// Per-wapp unread counts that drive the launcher tile badge (e.g. the APRS
/// app icon on the main panel). Session-scoped and in-memory: an open WappPage
/// pushes its authoritative total (summed conversation unread + geo-chat
/// unread) via [setCount], and the background manager increments via [add] on
/// each `notify` a closed wapp emits. Keyed by the wapp folder name (the same
/// id the launcher and BackgroundWappManager use).
class WappUnreadService {
  WappUnreadService._();
  static final WappUnreadService instance = WappUnreadService._();

  /// wappId -> unread count (entries with 0 are removed). Listen to badge tiles.
  final ValueNotifier<Map<String, int>> counts =
      ValueNotifier<Map<String, int>>(const {});

  int countFor(String wappId) => counts.value[wappId] ?? 0;

  /// Set the authoritative count for [wappId]; 0/negative clears it.
  void setCount(String wappId, int n) {
    if ((counts.value[wappId] ?? 0) == (n > 0 ? n : 0)) return;
    final m = Map<String, int>.from(counts.value);
    if (n > 0) {
      m[wappId] = n;
    } else {
      m.remove(wappId);
    }
    counts.value = m;
  }

  void add(String wappId, int n) => setCount(wappId, countFor(wappId) + n);

  void clear(String wappId) => setCount(wappId, 0);
}
