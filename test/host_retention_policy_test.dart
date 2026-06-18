import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/services/social/retention_tier.dart';
import 'package:aurora/services/social/host_retention_policy.dart';

void main() {
  const gb = 1 << 30;
  HostQuota quota({int ceilingGb = 100, int sliceGb = 100, int notes = 1000, int days = 1825}) =>
      HostQuota(
        ceilingBytes: ceilingGb * gb,
        strangerSliceBytes: sliceGb * gb,
        strangerNotesPerMonth: notes,
        strangerRetentionMs: days * 24 * 60 * 60 * 1000,
      );

  group('tierOf', () {
    final follows = {'aa' * 32};
    test('self wins over follow', () {
      expect(tierOf('bb' * 32, selfPubHex: 'bb' * 32, followsHex: follows), Tier.self);
    });
    test('followed', () {
      expect(tierOf('aa' * 32, selfPubHex: 'bb' * 32, followsHex: follows), Tier.followed);
    });
    test('stranger', () {
      expect(tierOf('cc' * 32, selfPubHex: 'bb' * 32, followsHex: follows), Tier.stranger);
    });
    test('no self key', () {
      expect(tierOf('bb' * 32, selfPubHex: null, followsHex: follows), Tier.stranger);
    });
  });

  group('admit', () {
    test('self is always accepted', () {
      final d = admit(Tier.self, 50 * gb, isMedia: true,
          totalHostedBytes: 99 * gb, strangerHostedBytes: 0,
          strangerNotesThisMonth: 0, q: quota());
      expect(d.ok, isTrue);
    });
    test('stranger refused past monthly note cap', () {
      final d = admit(Tier.stranger, 100, isMedia: false,
          totalHostedBytes: 0, strangerHostedBytes: 0,
          strangerNotesThisMonth: 1000, q: quota(notes: 1000));
      expect(d.ok, isFalse);
      expect(d.reason, contains('monthly'));
    });
    test('stranger refused past slice', () {
      final d = admit(Tier.stranger, 2 * gb, isMedia: true,
          totalHostedBytes: 0, strangerHostedBytes: 99 * gb,
          strangerNotesThisMonth: 0, q: quota(sliceGb: 100));
      expect(d.ok, isFalse);
      expect(d.reason, contains('stranger storage'));
    });
    test('followed accepted even when over ceiling (eviction frees later)', () {
      final d = admit(Tier.followed, 1 * gb, isMedia: true,
          totalHostedBytes: 100 * gb, strangerHostedBytes: 0,
          strangerNotesThisMonth: 0, q: quota(ceilingGb: 100));
      expect(d.ok, isTrue);
    });
    test('item bigger than ceiling refused for non-self', () {
      final d = admit(Tier.followed, 101 * gb, isMedia: true,
          totalHostedBytes: 0, strangerHostedBytes: 0,
          strangerNotesThisMonth: 0, q: quota(ceilingGb: 100));
      expect(d.ok, isFalse);
    });
  });

  group('planEviction', () {
    const now = 1000000000000;
    test('keeps self + followed text, drops stranger then followed media', () {
      final items = [
        StoredItem('self-note', Tier.self, 10 * gb, now, false),
        StoredItem('self-media', Tier.self, 30 * gb, now, true),
        StoredItem('fol-text', Tier.followed, 5 * gb, now, false),
        StoredItem('fol-media-big', Tier.followed, 40 * gb, now, true),
        StoredItem('fol-media-small', Tier.followed, 10 * gb, now, true),
        StoredItem('str-old', Tier.stranger, 20 * gb, now, true),
      ];
      // total = 115 GB, ceiling 100 GB -> must shed 15 GB.
      final del = planEviction(items, quota(ceilingGb: 100, sliceGb: 100), nowMs: now);
      // Stranger dropped first (20 GB) which already gets us under 100; followed
      // media not needed yet.
      expect(del, contains('str-old'));
      expect(del, isNot(contains('self-note')));
      expect(del, isNot(contains('self-media')));
      expect(del, isNot(contains('fol-text')));
    });
    test('drops followed media largest-first when strangers not enough', () {
      final items = [
        StoredItem('fol-text', Tier.followed, 5 * gb, now, false),
        StoredItem('fol-media-big', Tier.followed, 70 * gb, now, true),
        StoredItem('fol-media-small', Tier.followed, 40 * gb, now, true),
      ];
      // total 115 GB, ceiling 100 -> shed 15 GB, no strangers -> drop biggest media.
      final del = planEviction(items, quota(ceilingGb: 100), nowMs: now);
      expect(del, contains('fol-media-big'));
      expect(del, isNot(contains('fol-text')));
    });
    test('stranger past retention age always dropped', () {
      final old = now - (2000 * 24 * 60 * 60 * 1000); // > 1825 days
      final items = [
        StoredItem('str-ancient', Tier.stranger, 1 * gb, old, false),
        StoredItem('self', Tier.self, 1 * gb, now, false),
      ];
      final del = planEviction(items, quota(ceilingGb: 100, days: 1825), nowMs: now);
      expect(del, contains('str-ancient'));
      expect(del, isNot(contains('self')));
    });
  });
}
