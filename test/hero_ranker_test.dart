/*
 * The hero's ranking rules, as the user stated them:
 *
 *   "the algorithm initially picks the most relevant nostr posts when the user
 *    first installs the app, but as soon as the user starts following accounts
 *    then I want the algorithm to focus on the posts made from those accounts"
 *
 * Follows-only is STRICT: once you follow anyone, no stranger's post may appear,
 * however viral. That is the property most at risk from a well-meaning future
 * change ("just top up the empty slots from discovery…"), so it is asserted from
 * several angles here.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/services/hero/hero_item.dart';
import 'package:aurora/services/hero/hero_ranker.dart';

final _now = DateTime(2026, 7, 12, 12, 0);

HeroItem _nostr(
  String id, {
  required String author,
  int likes = 0,
  int replies = 0,
  Duration age = Duration.zero,
  bool image = false,
  String? title,
}) =>
    HeroItem(
      id: 'nostr:$id',
      sourceId: kHeroSourceNostr,
      intent: 'social',
      title: title ?? 'post $id',
      summary: '',
      createdAt: _now.subtract(age),
      authorPubkey: author,
      authorName: author,
      likes: likes,
      replies: replies,
      imageUrl: image ? 'https://example.org/$id.jpg' : null,
    );

HeroItem _wapp(
  String wappId,
  String id, {
  Duration age = Duration.zero,
  int priority = 0,
}) =>
    HeroItem(
      id: '$wappId:$id',
      sourceId: wappId,
      intent: 'blog',
      title: '$wappId $id',
      summary: '',
      createdAt: _now.subtract(age),
      authorName: wappId,
      priority: priority,
    );

void main() {
  group('follows-only, strict', () {
    test('a followed author beats a viral stranger — and the stranger is GONE',
        () {
      final viral = _nostr('viral', author: 'stranger', likes: 5000, replies: 900);
      final quiet = _nostr('quiet', author: 'alice');

      final out = rankHero([viral, quiet],
          follows: {'alice'}, limit: 10, now: _now);

      expect(out.map((i) => i.id), ['nostr:quiet'],
          reason: 'following someone means the hero is theirs — a stranger with '
              '5000 likes must not appear at all, not even in a spare slot');
    });

    test('an empty slot is left empty rather than filled with a stranger', () {
      final strangers = [
        for (var i = 0; i < 20; i++)
          _nostr('s$i', author: 'stranger$i', likes: 100 + i),
      ];
      final mine = _nostr('m1', author: 'alice');

      final out = rankHero([...strangers, mine],
          follows: {'alice'}, limit: 10, now: _now);

      expect(out.length, 1);
      expect(out.single.authorPubkey, 'alice');
    });

    test('a stale followed post still beats nothing (mirror backfill)', () {
      final old = _nostr('old', author: 'alice', age: const Duration(days: 3));
      final out =
          rankHero([old], follows: {'alice'}, limit: 10, now: _now);
      expect(out.single.id, 'nostr:old');
    });
  });

  group('cold start (nobody followed)', () {
    test('ranks by engagement, replies weighing more than likes', () {
      final liked = _nostr('liked', author: 'a', likes: 10);
      final discussed = _nostr('discussed', author: 'b', replies: 10);

      final out = rankHero([liked, discussed],
          follows: const {}, limit: 10, now: _now);

      expect(out.first.id, 'nostr:discussed',
          reason: 'a conversation beats a pile of drive-by likes');
    });

    test('a fresh post beats an equally-liked old one', () {
      final fresh = _nostr('fresh', author: 'a', likes: 10);
      final stale =
          _nostr('stale', author: 'b', likes: 10, age: const Duration(days: 2));

      final out =
          rankHero([fresh, stale], follows: const {}, limit: 10, now: _now);
      expect(out.first.id, 'nostr:fresh');
    });

    test('an image post is boosted over an identical text post', () {
      final withPic = _nostr('pic', author: 'a', likes: 10, image: true);
      final noPic = _nostr('txt', author: 'b', likes: 10);

      final out =
          rankHero([withPic, noPic], follows: const {}, limit: 10, now: _now);
      expect(out.first.id, 'nostr:pic',
          reason: 'the hero is a picture surface — a post with a backdrop is '
              'worth more to it than one without');
    });
  });

  test('one loud author cannot own the carousel', () {
    final loud = [
      for (var i = 0; i < 10; i++)
        _nostr('l$i', author: 'alice', likes: 100, age: Duration(minutes: i)),
    ];
    final others = [
      _nostr('b1', author: 'bob'),
      _nostr('c1', author: 'carol'),
    ];

    final out = rankHero([...loud, ...others],
        follows: {'alice', 'bob', 'carol'}, limit: 10, now: _now);

    // Everything gets in (the feed is thin), but alice must not be at the top of
    // the whole list — bob and carol come before her 3rd post.
    final firstThree = out.take(3).map((i) => i.authorPubkey).toSet();
    expect(firstThree.length, greaterThan(1),
        reason: 'the top of the carousel must not be one person ten times');
    expect(out.take(4).where((i) => i.authorPubkey == 'alice').length, 2,
        reason: 'per-author cap of 2 before anyone else is considered');
  });

  group('wapp items', () {
    test('are RESERVED slots — an engagement-less blog post still gets in', () {
      // Ten viral NOSTR posts. On score alone the blog entry would never place;
      // the reservation is the whole point of a generic hero.
      final nostr = [
        for (var i = 0; i < 10; i++)
          _nostr('n$i', author: 'a$i', likes: 500, replies: 100),
      ];
      final blog = _wapp('blog', 'e1');

      final out = rankHero([...nostr, blog],
          follows: const {}, limit: 10, now: _now);

      expect(out.any((i) => i.id == 'blog:e1'), isTrue);
      expect(out.length, 10);
    });

    test('one chatty wapp cannot flood the hero', () {
      final spam = [
        for (var i = 0; i < 20; i++) _wapp('spam', 'x$i', priority: 2),
      ];
      final nostr = [
        for (var i = 0; i < 10; i++) _nostr('n$i', author: 'a$i', likes: 5),
      ];

      final out =
          rankHero([...spam, ...nostr], follows: const {}, limit: 10, now: _now);

      expect(out.where((i) => i.sourceId == 'spam').length, 2,
          reason: 'max 2 slots per wapp, whatever priority it claims');
    });

    test('several wapps share the wapp budget, never more than 4 of 10', () {
      final items = [
        for (final w in ['blog', 'tasks', 'radio', 'notes', 'wiki'])
          for (var i = 0; i < 3; i++) _wapp(w, '$i'),
        for (var i = 0; i < 10; i++) _nostr('n$i', author: 'a$i', likes: 50),
      ];

      final out = rankHero(items, follows: const {}, limit: 10, now: _now);

      expect(out.where((i) => !i.isNostr).length, 4);
      expect(out.length, 10);
    });

    test('survive follows-only mode — they are not strangers', () {
      final out = rankHero(
        [_wapp('blog', 'e1'), _nostr('s', author: 'stranger', likes: 900)],
        follows: {'alice'},
        limit: 10,
        now: _now,
      );
      expect(out.map((i) => i.id), ['blog:e1'],
          reason: 'a wapp you installed is not a stranger on the network');
    });

    test('fill the hero on a device with no NOSTR at all', () {
      final items = [for (var i = 0; i < 8; i++) _wapp('blog$i', 'e$i')];
      final out = rankHero(items, follows: const {}, limit: 10, now: _now);
      expect(out.length, 8, reason: 'the wapp budget is a cap on competition, '
          'not a cap on an otherwise-empty hero');
    });
  });

  group('hygiene', () {
    test('an expired wapp item never shows', () {
      final dead = HeroItem(
        id: 'blog:old',
        sourceId: 'blog',
        title: 'gone',
        summary: '',
        createdAt: _now.subtract(const Duration(days: 2)),
        expiresAt: _now.subtract(const Duration(hours: 1)),
        authorName: 'blog',
      );
      expect(rankHero([dead], follows: const {}, limit: 10, now: _now), isEmpty);
    });

    test('the same event delivered twice takes one slot', () {
      final a = _nostr('dup', author: 'alice');
      final b = _nostr('dup', author: 'alice');
      final out = rankHero([a, b], follows: {'alice'}, limit: 10, now: _now);
      expect(out.length, 1);
    });

    test('a repost of the same words by the same author is not two cards', () {
      final a = _nostr('x1', author: 'alice', title: 'hello world');
      final b = _nostr('x2', author: 'alice', title: 'hello world');
      final out = rankHero([a, b], follows: {'alice'}, limit: 10, now: _now);
      expect(out.length, 1);
    });

    test('never returns more than the limit', () {
      final items = [
        for (var i = 0; i < 50; i++) _nostr('n$i', author: 'a$i', likes: i),
      ];
      expect(rankHero(items, follows: const {}, limit: 10, now: _now).length, 10);
    });
  });
}
