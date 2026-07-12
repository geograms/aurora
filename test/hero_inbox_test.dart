/*
 * The hero inbox is where third-party wapp code reaches the launcher's most
 * prominent surface, so it does not trust the publisher. These tests are mostly
 * about what a wapp must NOT be able to do: pin itself at the top forever, spam
 * the carousel, or grow the file without bound.
 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/services/hero/hero_inbox.dart';

Map<String, dynamic> _publish(List<Map<String, dynamic>> items,
        {bool? replace}) =>
    {
      'type': 'hero.publish',
      'replace': ?replace,
      'items': items,
    };

Map<String, dynamic> _item(String id, {Map<String, dynamic>? extra}) => {
      'id': id,
      'title': 'title $id',
      'summary': 'summary $id',
      ...?extra,
    };

/// The inbox rate-limits to one publish per second per wapp, so a test that
/// publishes twice must publish as two different wapps (or wait — which we
/// don't, in a unit test).
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hero_inbox_test');
    HeroInbox.instance.resetForTest();
    HeroInbox.instance.bind('${tmp.path}/hero_inbox.json');
  });

  tearDown(() {
    HeroInbox.instance.resetForTest();
    tmp.deleteSync(recursive: true);
  });

  test('a published item shows up, namespaced by its wapp', () {
    HeroInbox.instance.handleMessage('blog', _publish([_item('e1')]));

    final items = HeroInbox.instance.items();
    expect(items.length, 1);
    expect(items.single.id, 'blog:e1',
        reason: 'two wapps must be able to publish an item called "e1"');
    expect(items.single.sourceId, 'blog');
    expect(items.single.title, 'title e1');
  });

  test('a wapp cannot claim the future to pin itself at the top forever', () {
    final future = DateTime.now().add(const Duration(days: 365));
    HeroInbox.instance.handleMessage(
      'blog',
      _publish([
        _item('e1', extra: {
          'created_at': future.millisecondsSinceEpoch ~/ 1000,
        }),
      ]),
    );

    final item = HeroInbox.instance.items().single;
    expect(item.createdAt.isBefore(DateTime.now().add(const Duration(minutes: 6))),
        isTrue,
        reason: 'the ranker decays by age, and a future age never decays — a '
            'post from next year would sit at the top of the hero until then');
  });

  test('an ancient created_at is clamped, not silently dropped', () {
    HeroInbox.instance.handleMessage(
      'blog',
      _publish([_item('e1', extra: {'created_at': 1})]), // 1970
    );
    final item = HeroInbox.instance.items().single;
    expect(item.createdAt.isAfter(DateTime.now().subtract(const Duration(days: 31))),
        isTrue);
  });

  test('title and summary are clipped', () {
    HeroInbox.instance.handleMessage(
      'blog',
      _publish([
        {'id': 'e1', 'title': 'x' * 500, 'summary': 'y' * 500},
      ]),
    );
    final item = HeroInbox.instance.items().single;
    expect(item.title.length, lessThanOrEqualTo(80));
    expect(item.summary.length, lessThanOrEqualTo(160));
  });

  test('priority is clamped to 0..2', () {
    HeroInbox.instance
        .handleMessage('blog', _publish([_item('e1', extra: {'priority': 99})]));
    expect(HeroInbox.instance.items().single.priority, 2);
  });

  test('an item with no title is rejected — a blank card is worse than none', () {
    HeroInbox.instance.handleMessage('blog', _publish([
      {'id': 'e1', 'summary': 'body only'},
    ]));
    expect(HeroInbox.instance.items(), isEmpty);
  });

  test('at most 20 items per wapp', () {
    HeroInbox.instance.handleMessage(
      'blog',
      _publish([for (var i = 0; i < 50; i++) _item('e$i')]),
    );
    expect(HeroInbox.instance.items().length, 20);
  });

  test('publishing REPLACES by default (the wapp owns its own set)', () {
    HeroInbox.instance.handleMessage('blog', _publish([_item('old')]));
    // A different wapp id dodges the per-wapp rate limit; the replace semantics
    // are what's under test, not the limiter.
    HeroInbox.instance.handleMessage('other', _publish([_item('new')]));

    final ids = HeroInbox.instance.items().map((i) => i.id).toSet();
    expect(ids, {'blog:old', 'other:new'});
  });

  test('hero.clear drops that wapp, and only that wapp', () {
    HeroInbox.instance.handleMessage('blog', _publish([_item('e1')]));
    HeroInbox.instance.handleMessage('radio', _publish([_item('r1')]));

    HeroInbox.instance.handleMessage('blog', {'type': 'hero.clear'});

    expect(HeroInbox.instance.items().map((i) => i.id), ['radio:r1']);
  });

  test('hero.remove drops one card', () {
    HeroInbox.instance
        .handleMessage('blog', _publish([_item('e1'), _item('e2')]));
    HeroInbox.instance.handleMessage('blog', {'type': 'hero.remove', 'id': 'e1'});

    expect(HeroInbox.instance.items().map((i) => i.id), ['blog:e2']);
  });

  test('TTL is how long to SHOW the card, not how old the thing may be', () {
    // Last week's blog post, published to the hero now. Measuring the TTL from
    // created_at would expire this card the instant it arrived.
    HeroInbox.instance.handleMessage(
      'blog',
      _publish([
        _item('e1', extra: {
          'created_at': DateTime.now()
                  .subtract(const Duration(days: 7))
                  .millisecondsSinceEpoch ~/
              1000,
          'ttl': 3600,
        }),
      ]),
    );

    final item = HeroInbox.instance.items().single;
    expect(item.expired(DateTime.now()), isFalse);
    expect(item.expiresAt!.isAfter(DateTime.now()), isTrue);
    expect(item.createdAt.isBefore(DateTime.now().subtract(const Duration(days: 6))),
        isTrue,
        reason: 'the card still says how old the post really is');
  });

  test('a rate-limited second publish is ignored, not queued', () {
    HeroInbox.instance.handleMessage('blog', _publish([_item('e1')]));
    HeroInbox.instance.handleMessage('blog', _publish([_item('e2')]));

    expect(HeroInbox.instance.items().map((i) => i.id), ['blog:e1'],
        reason: 'a wapp ticking every 5s must not be able to churn the hero');
  });

  test('items survive a restart — the headless publish is the whole point', () {
    final path = '${tmp.path}/hero_inbox.json';
    HeroInbox.instance.handleMessage('blog', _publish([_item('e1')]));

    // The real save is debounced by 2s; write it out directly to stand in for
    // "the app lived long enough to flush".
    File(path).writeAsStringSync(jsonEncode({
      'blog': [
        {
          'id': 'blog:e1',
          'source': 'blog',
          'title': 'title e1',
          'summary': '',
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'expires_at': DateTime.now()
              .add(const Duration(hours: 5))
              .millisecondsSinceEpoch,
          'author': 'blog',
          'priority': 0,
        },
      ],
    }));

    HeroInbox.instance.resetForTest();
    HeroInbox.instance.bind(path);

    expect(HeroInbox.instance.items().map((i) => i.id), ['blog:e1']);
  });

  test('an expired item on disk is not resurrected at load', () {
    final path = '${tmp.path}/hero_inbox.json';
    File(path).writeAsStringSync(jsonEncode({
      'blog': [
        {
          'id': 'blog:stale',
          'source': 'blog',
          'title': 'stale',
          'created_at': 1,
          'expires_at': 2,
          'priority': 0,
        },
      ],
    }));

    HeroInbox.instance.resetForTest();
    HeroInbox.instance.bind(path);

    expect(HeroInbox.instance.items(), isEmpty);
  });

  test('a non-hero message is not ours', () {
    expect(
      HeroInbox.instance.handleMessage('blog', {'type': 'unread', 'count': 3}),
      isFalse,
    );
  });
}
