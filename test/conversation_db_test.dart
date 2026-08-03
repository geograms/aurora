// Durable conversation history: the properties that had to hold for a phone
// to stop losing every message it had ever received.
import 'dart:ffi';
import 'dart:io';

import 'package:aurora/wapp/geoui/conversation_db.dart';
import 'package:aurora/wapp/geoui/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('convo_db_test');
    dbPath = '${tmp.path}/conversations.sqlite3';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConversationStore attached(ConversationDb db, {String field = 'conversations'}) =>
      ConversationStore()
        ..db = db
        ..dbField = field
        ..loaded = true;

  test('messages survive close and reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'lxmf:abc', 'title': 'X1RD89'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'in', 'text': 'LIVE-D2P-001'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'out', 'text': 'LIVE-P2D-001'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = ConversationStore();
    db2.loadInto('conversations', restored);
    expect(restored.items['lxmf:abc']!.title, 'X1RD89');
    expect(
      restored.items['lxmf:abc']!.messages.map((m) => m['text']).toList(),
      ['LIVE-D2P-001', 'LIVE-P2D-001'],
    );
    db2.close();
  });

  test('a store that failed to load never writes', () {
    // Seed real history.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c1', 'title': 'kept'});
    store.addMessage({'id': 'c1', 'dir': 'in', 'text': 'precious'});
    db.close();

    // A page whose restore threw: db handle present, loaded false.
    final db2 = ConversationDb.open(dbPath);
    final broken = ConversationStore()
      ..db = db2
      ..dbField = 'conversations'
      ..loaded = false;
    broken.upsert({'id': 'c1', 'title': 'clobbered'});
    broken.addMessage({'id': 'c1', 'dir': 'in', 'text': 'overwrite'});
    broken.clear();
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = ConversationStore();
    db3.loadInto('conversations', check);
    expect(check.items['c1']?.title, 'kept', reason: 'history was overwritten');
    expect(check.items['c1']!.messages.single['text'], 'precious');
    db3.close();
  });

  test('a message carrying a mid is stored once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < 3; i++) {
      store.addMessage(
          {'id': 'g', 'dir': 'in', 'text': 'hello', 'mid': 'abc123'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = ConversationStore();
    db2.loadInto('conversations', restored);
    expect(restored.items['g']!.messages, hasLength(1));
    db2.close();
  });

  test('the same message re-emitted after an engine restart shows once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // No mid (a 1:1 LXMF message), same content signature both times.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    db.close();

    // Engine restarts, re-reads the durable inbox, re-emits the same message.
    final db2 = ConversationDb.open(dbPath);
    final reloaded = ConversationStore()..dbField = 'conversations';
    db2.loadInto('conversations', reloaded);
    reloaded
      ..db = db2
      ..loaded = true;
    reloaded
        .addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    expect(reloaded.items['c']!.messages, hasLength(1));
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = ConversationStore();
    db3.loadInto('conversations', check);
    expect(check.items['c']!.messages, hasLength(1));
    db3.close();
  });

  test('a database written before the ckey column still opens', () {
    // Simulate the older schema exactly: no ckey column, one stored message.
    final legacyDb = ConversationDb.open(dbPath);
    legacyDb.close();
    final raw = sqlite3.open(dbPath);
    raw.execute('DROP INDEX IF EXISTS msg_key');
    raw.execute('ALTER TABLE messages DROP COLUMN ckey');
    raw.execute(
        "INSERT INTO messages(field, convo_id, mid, body) VALUES('conversations','c','', ?)",
        ['{"dir":"in","text":"older build"}']);
    raw.dispose();

    final db = ConversationDb.open(dbPath); // must NOT throw
    final restored = ConversationStore();
    db.loadInto('conversations', restored);
    expect(restored.items['c']!.messages.single['text'], 'older build');
    db.close();
  });

  test('two engines emitting the same message id show one bubble', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // Page engine and headless engine each cursor the host inbox from 0 and
    // re-emit the same LXMF message: same mid (its hash), no content key.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    expect(store.items['c']!.messages, hasLength(1));
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final check = ConversationStore();
    db2.loadInto('conversations', check);
    expect(check.items['c']!.messages, hasLength(1));
    db2.close();
  });

  test('legacy JSON imports once, then the DB owns the history', () {
    final legacy = ConversationStore();
    legacy.upsert({'id': 'old', 'title': 'from json'});
    legacy.addMessage({'id': 'old', 'dir': 'in', 'text': 'archived'});

    final db = ConversationDb.open(dbPath);
    expect(db.hasField('conversations'), isFalse);
    db.importStore('conversations', legacy);
    expect(db.hasField('conversations'), isTrue);

    final restored = ConversationStore();
    db.loadInto('conversations', restored);
    expect(restored.items['old']!.messages.single['text'], 'archived');
    db.close();
  });

  test('delivery receipts and reactions survive a reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.addMessage(
        {'id': 'c', 'dir': 'out', 'text': 'hi', 'rid': 'r1', 'mid': 'm1'});
    store.setStatus({'rid': 'r1', 'status': 'delivered'});
    store.react({'mid': 'm1', 'from': 'someone'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = ConversationStore();
    db2.loadInto('conversations', restored);
    final msg = restored.items['c']!.messages.single;
    expect(msg['status'], 'delivered');
    expect(msg['likes'], 1);
    db2.close();
  });

  test('the per-thread cap is enforced on disk', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < kConvoMaxMessages + 25; i++) {
      store.addMessage({'id': 'big', 'dir': 'in', 'text': 'm$i'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = ConversationStore();
    db2.loadInto('conversations', restored);
    final msgs = restored.items['big']!.messages;
    expect(msgs, hasLength(kConvoMaxMessages));
    expect(msgs.last['text'], 'm${kConvoMaxMessages + 24}');
    db2.close();
  });
}
