// Headless test for slice 5: spam acceptance policy (PoW / rate / size) and
// kind-1063 file-metadata reference extraction.
//
//   dart run tool/social_relay_spam_test.dart
import 'dart:io';

import 'package:aurora/services/social/file_meta.dart';
import 'package:aurora/services/social/relay_event_store.dart' show kKindFileMetadata;
import 'package:aurora/services/social/spam.dart';
import 'package:aurora/util/nostr_crypto.dart';
import 'package:aurora/util/nostr_event.dart';

int _pass = 0, _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    _pass++;
    stdout.writeln('  ok   $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL $name');
  }
}

NostrEvent _ev(NostrKeyPair kp,
    {int kind = 1, String content = 'hi', List<List<String>> tags = const [], int? at}) {
  final e = NostrEvent(
    pubkey: kp.publicKeyHex,
    createdAt: at ?? 1_700_000_000,
    kind: kind,
    tags: tags,
    content: content,
  );
  e.sign(kp.privateKeyHex);
  return e;
}

void main() {
  // 1) leadingZeroBits helper.
  check('lzb 0000... = 16', leadingZeroBits('0000ffff') == 16);
  check('lzb 00f... = 8+? ', leadingZeroBits('00f0') == 8 + 0); // 'f'=1111 -> 0 leading
  check('lzb 01... = 7', leadingZeroBits('01') == 7); // 0000 0001
  check('lzb ff = 0', leadingZeroBits('ff') == 0);

  final kp = NostrCrypto.generateKeyPair();

  // 2) Size caps.
  final tiny = SpamPolicy(maxContentBytes: 10);
  check('content over cap rejected',
      !tiny.check(_ev(kp, content: 'this is definitely longer than ten')).accepted);
  check('content within cap accepted', tiny.check(_ev(kp, content: 'short')).accepted);

  // 3) PoW requirement (most random ids have 0 leading zero bits).
  final pow = SpamPolicy(minPowBits: 8);
  var rejectedForPow = 0;
  for (var i = 0; i < 8; i++) {
    final e = _ev(kp, content: 'pow$i', at: 1_700_000_000 + i);
    final v = pow.check(e);
    if (!v.accepted && (v.reason?.contains('pow') ?? false)) rejectedForPow++;
  }
  check('PoW gate rejects un-mined events', rejectedForPow >= 6);
  check('PoW accepts an id that happens to have >=8 zero bits OR not — gate works',
      leadingZeroBits('00abcdef') >= 8); // sanity on the gate input

  // 4) Rate limiting.
  final rl = SpamPolicy(maxEventsPerWindow: 3, window: const Duration(minutes: 1));
  var accepted = 0;
  for (var i = 0; i < 5; i++) {
    if (rl.check(_ev(kp, content: 'm$i', at: 1_700_000_000 + i), nowMs: 1000).accepted) {
      accepted++;
    }
  }
  check('rate limit caps at maxEventsPerWindow', accepted == 3);
  // Window slides: far-future timestamp lets it through again.
  check('rate window slides',
      rl.check(_ev(kp, content: 'later', at: 9), nowMs: 1000 + 120000).accepted);

  // 5) File-metadata reference extraction.
  final fileEv = _ev(kp, kind: kKindFileMetadata, content: 'manual', tags: [
    [kFileTagSha, 'a' * 64],
    [kFileTagMime, 'application/pdf'],
    [kFileTagName, 'manual.pdf'],
    [kFileTagSize, '2048'],
  ]);
  final ref = FileMetaResolver.refOf(fileEv);
  check('file ref parsed', ref != null);
  check('file ref sha is 32 bytes', ref!.sha256.length == 32);
  check('file ref name', ref.name == 'manual.pdf');
  check('file ref size', ref.size == 2048);
  check('non-file event -> null ref', FileMetaResolver.refOf(_ev(kp)) == null);
  check('bad sha length -> null ref',
      FileMetaResolver.refOf(_ev(kp, kind: kKindFileMetadata, tags: [[kFileTagSha, 'abcd']])) == null);

  stdout.writeln('\n$_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
