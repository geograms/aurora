/// The same notification, announced twice, is still ONE notification.
///
/// The social inbox is answered out of SQLite, so every app start replays the
/// stored reactions through the announce path. Without a durable identity for a
/// notification, each replay minted a new card and re-lit the bell — which is
/// exactly the "always a 1, always the same notification" the user saw.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/notification_service.dart';

void main() {
  setUp(() => NotificationService.instance.reset());

  test('a tagged notification is shown once, however many times it is raised',
      () {
    final n = GeogramNotification(
      level: NotificationLevel.info,
      title: 'someone liked your post',
      source: 'wapp:social',
      tag: 'nostr:abc123',
    );

    NotificationService.instance.show(n);
    NotificationService.instance.show(n); // a replay after a restart
    NotificationService.instance.show(n);

    expect(NotificationService.instance.history, hasLength(1),
        reason: 'the event id IS the identity; the same event is one card');
  });

  test('different events still get their own card', () {
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'A liked your post',
      source: 'wapp:social',
      tag: 'nostr:aaa',
    ));
    NotificationService.instance.show(GeogramNotification(
      level: NotificationLevel.info,
      title: 'B replied to you',
      source: 'wapp:social',
      tag: 'nostr:bbb',
    ));

    expect(NotificationService.instance.history, hasLength(2));
  });

  test('untagged notifications are untouched — no accidental suppression', () {
    for (var i = 0; i < 3; i++) {
      NotificationService.instance.show(GeogramNotification(
        level: NotificationLevel.info,
        title: 'build finished',
        source: 'host:updates',
      ));
    }
    expect(NotificationService.instance.history, hasLength(3));
  });
}
