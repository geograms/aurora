import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/util/time_ago.dart';
import 'package:aurora/wapp/geoui/widgets/activity_feed.dart' show activityTimeLabel;

void main() {
  final now = DateTime(2026, 7, 12, 12, 0);

  test('the boundaries read the way a person would say them', () {
    expect(timeAgo(now.subtract(const Duration(seconds: 10)), now: now),
        'just now');
    expect(timeAgo(now.subtract(const Duration(minutes: 1)), now: now),
        '1 minute ago');
    expect(timeAgo(now.subtract(const Duration(minutes: 19)), now: now),
        '19 minutes ago');
    expect(timeAgo(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago');
    expect(timeAgo(now.subtract(const Duration(hours: 3)), now: now),
        '3 hours ago');
    expect(timeAgo(now.subtract(const Duration(days: 1)), now: now),
        'yesterday');
    expect(timeAgo(DateTime(2026, 6, 26), now: now), 'Jun 26');
    expect(timeAgo(DateTime(2024, 6, 26), now: now), 'Jun 26 2024',
        reason: 'a different year needs the year, or it reads as this year');
  });

  test('a future timestamp (a peer with a bad clock) never says "in 3 hours"', () {
    expect(timeAgo(now.add(const Duration(hours: 3)), now: now), 'now');
  });

  test('activityTimeLabel still falls back to the wapp clock string with no epoch',
      () {
    expect(activityTimeLabel({'time': '14:03'}), '14:03');
  });

  test('activityTimeLabel uses the shared wording when it has an epoch', () {
    final t = DateTime.now().subtract(const Duration(minutes: 19));
    expect(activityTimeLabel({'t': t.millisecondsSinceEpoch, 'time': '14:03'}),
        '19 minutes ago');
  });
}
