/*
 * Pure store-and-forward retention/quota policy. Two responsibilities, both
 * side-effect-free so they unit-test headlessly (the runtime that reads the DBs
 * and deletes rows lives in the relay/archive layers):
 *
 *   admit()        - given a new item's tier/size and the current usage, decide
 *                    whether to accept it (and why not, for the reply).
 *   planEviction() - given the full hosted inventory and the budget, return the
 *                    item ids to delete, in order, honoring the tier rules:
 *                      never delete our own;
 *                      never delete a followed person's TEXT;
 *                      drop stranger items past their retention age first;
 *                      then drop strangers oldest-first to fit their slice / the
 *                      node ceiling;
 *                      then, only if still over the ceiling, drop followed MEDIA
 *                      largest-first.
 *
 * "Notes" (text) and "media" (binary blobs) share this policy; the caller sets
 * isMedia. The monthly note cap applies to stranger NOTES only.
 */
import 'retention_tier.dart';

/// Tunable limits for the host (sourced from PreferencesService at runtime).
class HostQuota {
  final int ceilingBytes; // whole-node hosting budget
  final int strangerSliceBytes; // strangers' slice within the ceiling
  final int strangerNotesPerMonth; // stranger text-note count cap per month
  final int strangerRetentionMs; // stranger items deletable after this age

  const HostQuota({
    required this.ceilingBytes,
    required this.strangerSliceBytes,
    required this.strangerNotesPerMonth,
    required this.strangerRetentionMs,
  });
}

class AdmitDecision {
  final bool ok;
  final String? reason; // null when ok
  const AdmitDecision(this.ok, [this.reason]);
}

/// One hosted item the eviction planner can reason about (a note or a blob).
class StoredItem {
  final String id; // event id (notes) or sha256 (blobs)
  final Tier tier;
  final int bytes;
  final int receivedAtMs; // when we accepted it
  final bool isMedia; // true = binary blob; false = text note
  const StoredItem(
      this.id, this.tier, this.bytes, this.receivedAtMs, this.isMedia);
}

/// Decide whether to accept a new item. [isMedia] selects the note vs blob caps.
AdmitDecision admit(
  Tier tier,
  int bytes, {
  required bool isMedia,
  required int totalHostedBytes,
  required int strangerHostedBytes,
  required int strangerNotesThisMonth,
  required HostQuota q,
}) {
  // Our own content is never refused.
  if (tier == Tier.self) return const AdmitDecision(true);

  // A single item bigger than the whole-node ceiling can never be hosted.
  if (bytes > q.ceilingBytes) {
    return const AdmitDecision(false, 'item exceeds node storage ceiling');
  }

  if (tier == Tier.followed) {
    // Accepted; if it overflows the ceiling, planEviction() frees room afterward
    // by dropping strangers / followed media — followed text is never dropped.
    return const AdmitDecision(true);
  }

  // stranger
  if (!isMedia && strangerNotesThisMonth >= q.strangerNotesPerMonth) {
    return const AdmitDecision(false, 'monthly note limit reached');
  }
  if (strangerHostedBytes + bytes > q.strangerSliceBytes) {
    return const AdmitDecision(false, 'stranger storage limit reached');
  }
  if (totalHostedBytes + bytes > q.ceilingBytes) {
    return const AdmitDecision(false, 'node storage full');
  }
  return const AdmitDecision(true);
}

/// Return the ids to delete, in order, to satisfy retention + budget rules.
List<String> planEviction(
  List<StoredItem> items,
  HostQuota q, {
  required int nowMs,
}) {
  final deleted = <String>{};
  final order = <String>[];
  void drop(StoredItem it) {
    if (deleted.add(it.id)) order.add(it.id);
  }

  var total = items.fold<int>(0, (s, it) => s + it.bytes);
  var strangerBytes = items
      .where((it) => it.tier == Tier.stranger)
      .fold<int>(0, (s, it) => s + it.bytes);

  // 1) Retention: stranger items older than the retention age go regardless.
  for (final it in items) {
    if (it.tier == Tier.stranger &&
        nowMs - it.receivedAtMs > q.strangerRetentionMs) {
      drop(it);
      total -= it.bytes;
      strangerBytes -= it.bytes;
    }
  }

  // 2) Strangers over their slice (or pushing the node over the ceiling):
  //    oldest first.
  final strangers = [
    for (final it in items)
      if (it.tier == Tier.stranger && !deleted.contains(it.id)) it
  ]..sort((a, b) => a.receivedAtMs.compareTo(b.receivedAtMs));
  for (final it in strangers) {
    if (strangerBytes <= q.strangerSliceBytes && total <= q.ceilingBytes) break;
    drop(it);
    total -= it.bytes;
    strangerBytes -= it.bytes;
  }

  // 3) Still over the ceiling -> drop followed MEDIA largest-first. Followed
  //    text and our own content are never touched.
  if (total > q.ceilingBytes) {
    final followedMedia = [
      for (final it in items)
        if (it.tier == Tier.followed && it.isMedia && !deleted.contains(it.id))
          it
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));
    for (final it in followedMedia) {
      if (total <= q.ceilingBytes) break;
      drop(it);
      total -= it.bytes;
    }
  }

  return order;
}
