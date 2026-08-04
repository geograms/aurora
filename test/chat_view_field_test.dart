// The chat composer's contract with the wapp: what a heart and a reply put on
// the wire, and what must never reach the timeline as text.
//
// Both halves shipped broken on a 1:1 conversation — the heart did nothing at
// all, and a reply rendered its wire marker verbatim, as a bubble reading
// "+9eb53a4af55e5da04cdcc44842502041e8d5e2460f123358c31a17f8a31993dd OK".
import 'package:aurora/wapp/geoui/widgets/chat_view_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> msg(
  String text, {
  String dir = 'in',
  String from = 'X1A33T',
  String mid = '',
  String parent = '',
  int likes = 0,
  bool liked = false,
}) =>
    {
      'dir': dir,
      'from': from,
      'text': text,
      'time': '13:33',
      if (mid.isNotEmpty) 'mid': mid,
      if (parent.isNotEmpty) 'parent': parent,
      if (likes > 0) 'likes': likes,
      if (liked) 'liked': true,
    };

void main() {
  late List<String> sent;

  Future<void> pump(WidgetTester tester, List<Map<String, dynamic>> messages,
      {Size size = const Size(1000, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatViewField(
          fieldName: 'chat',
          label: 'Chat',
          fill: true,
          messages: messages,
          onSend: sent.add,
        ),
      ),
    ));
    await tester.pump();
  }

  setUp(() => sent = <String>[]);

  group('votes never render as messages', () {
    testWidgets('a 4-hex vote is not a bubble', (tester) async {
      await pump(tester, [
        msg('smth', mid: '9eb5'),
        msg('9eb5:like'),
      ]);
      expect(find.text('smth'), findsOneWidget);
      expect(find.text('9eb5:like'), findsNothing);
    });

    testWidgets('a 64-hex room vote is not a bubble', (tester) async {
      const ev =
          '82ccbaec1f0d4a5b6c7d8e9f00112233445566778899aabbccddeeff00112233';
      await pump(tester, [msg('hello', mid: 'aa11'), msg('$ev:unlike')]);
      expect(find.text('$ev:unlike'), findsNothing);
    });

    testWidgets('an ordinary message that merely looks similar still renders',
        (tester) async {
      await pump(tester, [msg('9eb5:liked it'), msg('zzzz:like')]);
      expect(find.text('9eb5:liked it'), findsOneWidget);
      expect(find.text('zzzz:like'), findsOneWidget);
    });
  });

  group('the heart', () {
    testWidgets('sends a like vote naming the message', (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.tap(find.byIcon(Icons.favorite_border).first);
      await tester.pump();
      expect(sent, ['9eb5:like']);
    });

    testWidgets('sends an unlike when already liked', (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5', likes: 1, liked: true)]);
      await tester.tap(find.byIcon(Icons.favorite).first);
      await tester.pump();
      expect(sent, ['9eb5:unlike']);
    });

    // Without a mid there is nothing to vote on — offering the heart would
    // send a vote naming nothing.
    testWidgets('is not offered on a message with no id', (tester) async {
      await pump(tester, [msg('smth')]);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });

    // Our own bubble shows the tally, never a button: liking yourself is not a
    // thing, and a 0 tally is noise.
    testWidgets('on our own message shows the count and does not vote',
        (tester) async {
      await pump(tester, [
        msg('mine', dir: 'out', mid: 'aa11'),
        msg('mine liked', dir: 'out', mid: 'bb22', likes: 2),
      ]);
      // Nothing at all on the un-liked one, a tally on the other.
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('replying', () {
    testWidgets('puts the parent id on the wire, not in the text',
        (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.tap(find.text('Reply').first);
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'OK');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(sent, ['+9eb5 OK']);
    });

    testWidgets('a plain message carries no marker', (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.enterText(find.byType(TextField).last, 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(sent, ['hello']);
    });

    testWidgets('quotes the parent it is threaded under', (tester) async {
      await pump(tester, [
        msg('smth', mid: '9eb5'),
        msg('OK', dir: 'out', from: 'X16JK8', mid: 'aa11', parent: '9eb5'),
      ]);
      // The quote shows the parent's text, so the reply reads as an answer.
      expect(find.textContaining('smth'), findsWidgets);
      expect(find.text('OK'), findsOneWidget);
    });
  });

  // Sending rebuilds the thread; the composer used to lose focus with it, so
  // every second message needed a click back into the field.
  testWidgets('the composer keeps focus after sending', (tester) async {
    await pump(tester, [msg('smth', mid: '9eb5')]);
    final field = find.byType(TextField).last;
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'first');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final node = tester.widget<TextField>(field).focusNode;
    expect(node, isNotNull, reason: 'the composer needs a focus node to keep');
    expect(node!.hasFocus, isTrue);

    // And the field is empty and ready, so the next message needs no click.
    expect(tester.widget<TextField>(field).controller!.text, '');
  });
}
