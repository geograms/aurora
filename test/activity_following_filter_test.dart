import 'package:aurora/wapp/geoui/widgets/activity_feed.dart';
import 'package:flutter_test/flutter_test.dart';

String _key(String seed) => seed.padRight(64, '0').substring(0, 64);

void main() {
  final alice = _key('a1');
  final stranger = _key('b2');
  final self = _key('c3');

  test('Following accepts only exact full author pubkeys and self', () {
    expect(
      activityPostMatchesDirectFollows({'author': alice}, {alice}, self),
      isTrue,
    );
    expect(
      activityPostMatchesDirectFollows({'author': self}, {alice}, self),
      isTrue,
    );
    expect(
      activityPostMatchesDirectFollows({'author': stranger}, {alice}, self),
      isFalse,
    );
  });

  test('legacy short author rows cannot leak into Following', () {
    expect(
      activityPostMatchesDirectFollows(
        {'from': alice.substring(0, 12)},
        {alice},
        self,
      ),
      isFalse,
    );
    expect(
      activityPostMatchesDirectFollows(
        {'author': alice.substring(0, 12)},
        {alice},
        self,
      ),
      isFalse,
    );
  });

  test('legacy rows require an exact full-key profile resolution', () {
    final post = {'from': alice.substring(0, 12)};
    expect(
      activityPostMatchesDirectFollows(post, {alice}, self, (_) => alice),
      isTrue,
    );
    expect(
      activityPostMatchesDirectFollows(post, {alice}, self, (_) => stranger),
      isFalse,
    );
  });
}
