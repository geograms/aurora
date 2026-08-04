// Reactions: the tally, and telling the person whose message was liked.
//
// A like used to be a number that moved on a screen nobody was looking at —
// the recipient was never told. The store is what knows whose message a vote
// names, so it reports the ones worth surfacing and the callers notify.
import 'package:aurora/wapp/geoui/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ConversationStore store;

  setUp(() {
    store = ConversationStore();
    store.addMessage(
        {'id': 'c', 'dir': 'out', 'text': 'RT-1', 'mid': 'aa11', 'time': '14:28'});
    store.addMessage({
      'id': 'c',
      'dir': 'in',
      'from': 'X1A33T',
      'text': 'hi',
      'mid': 'bb22',
      'time': '14:29'
    });
  });

  test('someone liking our message is reported, with the message', () {
    final liked = store.react({'mid': 'aa11', 'from': 'X1A33T'});
    expect(liked, isNotNull);
    expect(liked!.convo, 'c');
    expect(liked.from, 'X1A33T');
    expect(liked.message['text'], 'RT-1');
  });

  test('the tally lands on the message either way', () {
    store.react({'mid': 'aa11', 'from': 'X1A33T'});
    final m = store.items['c']!.messages.first;
    expect(m['likes'], 1);
    expect(m['liked'], isNot(true)); // theirs, not ours
  });

  test('our own vote is not reported back to us', () {
    expect(store.react({'mid': 'aa11', 'from': 'me', 'mine': true}), isNull);
    expect(store.items['c']!.messages.first['liked'], true);
  });

  test('a like on their own message is not ours to hear about', () {
    expect(store.react({'mid': 'bb22', 'from': 'X1A33T'}), isNull);
    expect(store.items['c']!.messages.last['likes'], 1);
  });

  test('a retraction is not an event', () {
    store.react({'mid': 'aa11', 'from': 'X1A33T'});
    expect(
        store.react({'mid': 'aa11', 'from': 'X1A33T', 'remove': true}), isNull);
    expect(store.items['c']!.messages.first['likes'], 0);
  });

  // Messages that predate derived ids (and any vote naming something we never
  // received) resolve to nothing: count it, stay quiet.
  test('a vote naming a message we do not hold is silent', () {
    expect(store.react({'mid': 'ffff', 'from': 'X1A33T'}), isNull);
  });

  test('each liker counts once, however many times they vote', () {
    store.react({'mid': 'aa11', 'from': 'X1A33T'});
    store.react({'mid': 'aa11', 'from': 'X1A33T'});
    store.react({'mid': 'aa11', 'from': 'X1RD89'});
    expect(store.items['c']!.messages.first['likes'], 2);
  });

  // The case that made a like on an older message do nothing at all: the two
  // devices never agreed on an id for it. Ours has none; the vote names theirs.
  group('a vote naming an id we never had', () {
    setUp(() {
      // A message from before ids were derived: stored with no mid.
      store.addMessage(
          {'id': 'c', 'dir': 'out', 'text': 'smth', 'time': '13:51'});
    });

    test('finds the message by content and reports it', () {
      final liked = store.react({
        'id': 'c',
        'mid': 'deadbeef',
        'from': 'X1A33T',
        'ck': contentKey('smth', '13:51'),
      });
      expect(liked, isNotNull);
      expect(liked!.message['text'], 'smth');
    });

    test('adopts the id, so the tally lands and the next vote matches directly', () {
      store.react({
        'id': 'c',
        'mid': 'deadbeef',
        'from': 'X1A33T',
        'ck': contentKey('smth', '13:51'),
      });
      final m = store.items['c']!.messages.last;
      expect(m['mid'], 'deadbeef');
      expect(m['likes'], 1);

      // Retracting by id alone now works — no content key needed.
      store.react(
          {'id': 'c', 'mid': 'deadbeef', 'from': 'X1A33T', 'remove': true});
      expect(store.items['c']!.messages.last['likes'], 0);
    });

    test('an id we already hold wins over the voter\'s', () {
      store.react({
        'id': 'c',
        'mid': 'zzzz',
        'from': 'X1A33T',
        'ck': contentKey('RT-1', '14:28'),
      });
      final m = store.items['c']!.messages.first;
      expect(m['mid'], 'aa11'); // ours kept
      expect(m['likes'], 1); // and the tally still lands
    });
  });

  // "ok" gets sent all day. A like on this morning's must not move the count
  // on the newest one.
  group('repeated text', () {
    setUp(() {
      store.addMessage(
          {'id': 'c', 'dir': 'out', 'text': 'ok', 'time': '09:15'});
      store.addMessage(
          {'id': 'c', 'dir': 'out', 'text': 'ok', 'time': '17:40'});
    });

    test('the time picks the right one', () {
      store.react({
        'id': 'c',
        'mid': 'm-morning',
        'from': 'X1A33T',
        'ck': contentKey('ok', '09:15'),
      });
      final msgs = store.items['c']!.messages;
      final morning = msgs.firstWhere((m) => m['time'] == '09:15');
      final evening = msgs.firstWhere((m) => m['time'] == '17:40');
      expect(morning['likes'], 1);
      expect(evening['likes'], isNot(1));
    });

    test('a clock a minute out still finds the message', () {
      store.react({
        'id': 'c',
        'mid': 'm-x',
        'from': 'X1A33T',
        'ck': contentKey('ok', '17:41'), // their clock, not ours
      });
      // No exact minute matches, so the most recent copy takes it.
      final evening =
          store.items['c']!.messages.firstWhere((m) => m['time'] == '17:40');
      expect(evening['likes'], 1);
    });
  });
}
