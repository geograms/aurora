import 'dart:math' as math;

import 'hero_item.dart';

/// How many of the [limit] slots wapp-published items may take between them.
/// A blog post is never buried under a busy NOSTR day — and one chatty wapp can
/// never take the carousel either (see [_maxPerWapp]).
const int _wappSlotBudget = 4;
const int _maxPerWapp = 2;

/// No author may hold more than this many slots. Without it, the one person you
/// follow who posts thirty times a day owns the entire hero.
const int _maxPerAuthor = 2;

/// Engagement halves every N hours. Short in follows mode — you want to know
/// what the people you follow said *now*; longer at cold start, where a popular
/// post stays worth showing for a day.
const double _halfLifeFollows = 6.0;
const double _halfLifeCold = 24.0;

/// Score one item. Public only so the tests can assert the ordering directly.
double heroScore(HeroItem i, {required bool followsMode, required DateTime now}) {
  final ageHours =
      math.max(0, now.difference(i.createdAt).inMinutes) / 60.0;
  final halfLife = followsMode ? _halfLifeFollows : _halfLifeCold;
  // A reply beats a drive-by like: it is someone spending real effort.
  final engagement = 1 + i.likes + 2 * i.replies;
  final decay = math.pow(0.5, ageHours / halfLife).toDouble();
  final image = i.hasImage ? 1.35 : 1.0; // the hero needs a backdrop
  final priority = 1.0 + 0.25 * i.priority.clamp(0, 2);
  return engagement * decay * image * priority;
}

/// Pick and order the cards.
///
/// The rule the user asked for, and the one thing to preserve when touching
/// this: **once you follow anyone, the hero is theirs.** No global post, however
/// viral, may appear. A quiet timeline is backfilled with your follows' *older*
/// posts (the caller supplies those from the local mirror) — never with
/// strangers'.
///
/// Wapp-published items are not NOSTR and are not subject to that rule: a blog
/// entry from a wapp you installed is something you asked for too.
List<HeroItem> rankHero(
  List<HeroItem> candidates, {
  required Set<String> follows,
  required int limit,
  required DateTime now,
}) {
  final followsMode = follows.isNotEmpty;

  // Dedup by id, then by (title, author) so a repost of the same words doesn't
  // take two slots.
  final byId = <String, HeroItem>{};
  final seenText = <String>{};
  for (final i in candidates) {
    if (i.expired(now)) continue;
    if (byId.containsKey(i.id)) continue;
    final textKey = '${i.title}|${i.authorPubkey ?? i.authorName}';
    if (!seenText.add(textKey)) continue;
    byId[i.id] = i;
  }

  final pool = byId.values.where((i) {
    if (!i.isNostr) return true; // wapp items are never filtered by follows
    if (!followsMode) return true; // cold start: the discovery feed stands
    final pk = i.authorPubkey;
    return pk != null && follows.contains(pk);
  }).toList();

  int byScoreDesc(HeroItem a, HeroItem b) {
    final s = heroScore(b, followsMode: followsMode, now: now)
        .compareTo(heroScore(a, followsMode: followsMode, now: now));
    return s != 0 ? s : b.createdAt.compareTo(a.createdAt);
  }

  // Wapp items are RESERVED a share of the slots rather than left to compete on
  // score — an engagement-less blog post can never outscore a NOSTR post with
  // fifty likes, so "may compete" would mean "never appears". That would defeat
  // the whole point of a generic hero.
  final wappItems = pool.where((i) => !i.isNostr).toList()..sort(byScoreDesc);
  final nostrItems = pool.where((i) => i.isNostr).toList()..sort(byScoreDesc);

  final picked = <HeroItem>[];
  final perWapp = <String, int>{};
  for (final i in wappItems) {
    if (picked.length >= _wappSlotBudget) break;
    if ((perWapp[i.sourceId] ?? 0) >= _maxPerWapp) continue;
    perWapp[i.sourceId] = (perWapp[i.sourceId] ?? 0) + 1;
    picked.add(i);
  }

  final perAuthor = <String, int>{};
  final deferred = <HeroItem>[];
  for (final i in nostrItems) {
    if (picked.length == limit) break;
    final author = i.authorPubkey ?? i.authorName;
    if ((perAuthor[author] ?? 0) >= _maxPerAuthor) {
      // Hold it back rather than drop it: on a thin day a third post from a
      // chatty author still beats an empty slot.
      deferred.add(i);
      continue;
    }
    perAuthor[author] = (perAuthor[author] ?? 0) + 1;
    picked.add(i);
  }

  // Order the capped selection by score, so a reserved wapp item lands where it
  // deserves among the NOSTR posts rather than being pinned to the front.
  picked.sort(byScoreDesc);

  // Under-filled (few follows, quiet day): relax the caps rather than show a
  // short carousel — but APPEND the overflow, never merge it back into the sort.
  // Sorting it in would undo the per-author cap outright: a loud author's posts
  // all score high, so they would simply re-take the top of the list they were
  // just capped out of.
  final filler = [
    ...deferred,
    ...wappItems.where((w) => !picked.contains(w)),
  ]..sort(byScoreDesc);
  for (final i in filler) {
    if (picked.length == limit) break;
    picked.add(i);
  }

  return picked;
}
