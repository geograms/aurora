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
    store.addMessage({'id': 'c', 'dir': 'out', 'text': 'RT-1', 'mid': 'aa11'});
    store.addMessage(
        {'id': 'c', 'dir': 'in', 'from': 'X1A33T', 'text': 'hi', 'mid': 'bb22'});
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
}
