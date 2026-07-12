// Live-node FIXTURE (see hero_mirror_seed_test.dart).
//
// The other half of "cache what you follow and SERVE it": connect to the running
// device's own NOSTR relay endpoint as an outside client and ask for the post
// the mirror stored. It answers out of social.sqlite3 — the same store RelayNode
// serves to Reticulum peers — so a hit here is the serving path, checked from
// outside the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _author =
    '12e5a43da072636e831ad78af1f68776825df9f70d92641d73a702fbb44f4727';

/// The app's local NOSTR relay endpoint. Reachable only when a node is running
/// here, so this fixture skips itself everywhere else (CI included).
Future<bool> _nodeIsUp() async {
  try {
    final s = await Socket.connect('127.0.0.1', 4848,
        timeout: const Duration(milliseconds: 500));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('the device serves a followed author\'s post to a stranger', () async {
    if (!await _nodeIsUp()) {
      markTestSkipped('no live node listening on 127.0.0.1:4848');
      return;
    }
    final ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:4848'));
    await ch.ready.timeout(const Duration(seconds: 8));

    final events = <Map<String, dynamic>>[];
    final eose = Completer<void>();
    ch.stream.listen((d) {
      final m = jsonDecode(d as String);
      if (m is! List || m.isEmpty) return;
      if (m[0] == 'EVENT' && m.length >= 3) {
        events.add((m[2] as Map).cast<String, dynamic>());
      }
      if (m[0] == 'EOSE' && !eose.isCompleted) eose.complete();
    });

    ch.sink.add(jsonEncode([
      'REQ',
      'probe',
      {
        'authors': [_author],
        'kinds': [1],
      },
    ]));

    await eose.future.timeout(const Duration(seconds: 10));
    await ch.sink.close();

    // ignore: avoid_print
    print('SERVED ${events.length} event(s) for the followed author');
    for (final e in events) {
      // ignore: avoid_print
      print('  ${e['id']}  ${e['content']}');
    }

    expect(events, isNotEmpty,
        reason: 'the mirror stored this post; the relay must be able to hand '
            'it to another peer, or we are not a relay for the people we follow');
  });
}
