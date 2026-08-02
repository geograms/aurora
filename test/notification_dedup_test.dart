/// The same notification, announced twice, is still ONE notification.
///
/// The social inbox is answered out of SQLite, so every app start replays the
/// stored reactions through the announce path. Without a durable identity for a
/// notification, each replay minted a new card and re-lit the bell — which is
/// exactly the "always a 1, always the same notification" the user saw.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/services/announced_tags_store.dart';
import 'package:aurora/services/notification_service.dart';

void main() {
  setUp(() {
    NotificationService.instance.reset();
    AnnouncedTagsStore.instance.reset();
    // No profile storage in tests: mark the guard loaded-empty so show()
    // consults it instead of buffering until a load that never happens.
    AnnouncedTagsStore.instance.markLoadedForTest();
  });

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

  test('the guard is persistent: a service restart does not re-announce', () {
    final n = GeogramNotification(
      level: NotificationLevel.info,
      title: 'someone liked your post',
      source: 'wapp:social',
      tag: 'nostr:restart',
    );
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, hasLength(1));

    // "Restart": the service loses its memory, the announced store does not
    // (at runtime it reloads notifications/announced.txt from the profile).
    NotificationService.instance.reset();
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, isEmpty,
        reason: 'the persisted tag set outlives the process');
  });

  test('tagged notifications buffer until the guard has loaded', () {
    AnnouncedTagsStore.instance.reset(); // loaded = false again
    final n = GeogramNotification(
      level: NotificationLevel.info,
      title: 'early bird',
      source: 'wapp:social',
      tag: 'nostr:early',
    );
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, isEmpty,
        reason: 'guard not loaded: nothing may announce yet');
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
