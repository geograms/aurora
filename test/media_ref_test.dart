import 'package:flutter_test/flutter_test.dart';
import 'package:aurora/util/media_ref.dart';

void main() {
  // A syntactically valid 43-char base64url hash for fixtures.
  const h = 'qL0g2Zr5xW8yV1uT4sR7pQ0oN3mL6kJ9iH2gF5eD8cX';

  group('MediaRef.parse', () {
    test('valid tokens parse with the right fields', () {
      final r = MediaRef.parse('file:$h.png');
      expect(r, isNotNull);
      expect(r!.sha256, h);
      expect(r.ext, 'png');
      expect(r.kind, MediaKind.image);
      expect(r.token, 'file:$h.png');
    });

    test('garbage and near-misses return null', () {
      expect(MediaRef.parse('hello world'), isNull);
      expect(MediaRef.parse('file:$h'), isNull); // no extension
      expect(MediaRef.parse('file:short.png'), isNull); // hash too short
      expect(MediaRef.parse('file:$h.PNG'), isNull); // uppercase ext
      expect(MediaRef.parse('file:$h.png extra'), isNull); // trailing junk
      expect(MediaRef.parse('file:${h}x.png'), isNull); // hash too long
    });
  });

  group('MediaRef.findAll', () {
    test('finds tokens embedded in free text', () {
      final refs =
          MediaRef.findAll('sunset from the hill file:$h.jpg taken today');
      expect(refs, hasLength(1));
      expect(refs.first.ext, 'jpg');
      expect(refs.first.kind, MediaKind.image);
    });

    test('multiple tokens in one body', () {
      final refs = MediaRef.findAll('file:$h.png and file:$h.webm');
      expect(refs, hasLength(2));
      expect(refs[0].kind, MediaKind.image);
      expect(refs[1].kind, MediaKind.video);
    });

    test('trailing sentence punctuation stays outside the match', () {
      final refs = MediaRef.findAll('see file:$h.png.');
      expect(refs, hasLength(1));
      expect(refs.first.ext, 'png');
    });

    test('no tokens -> empty list', () {
      expect(MediaRef.findAll('just a plain message'), isEmpty);
    });
  });

  group('MediaRef.classify', () {
    test('images (incl. gif per APRX §16.3 — animated natively)', () {
      for (final e in ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg']) {
        expect(MediaRef.classify(e), MediaKind.image, reason: e);
      }
    });
    test('video', () {
      for (final e in ['webm', 'mpeg', 'mpg', 'mp4', 'mov']) {
        expect(MediaRef.classify(e), MediaKind.video, reason: e);
      }
    });
    test('audio', () {
      for (final e in ['mp3', 'ogg', 'flac', 'opus']) {
        expect(MediaRef.classify(e), MediaKind.audio, reason: e);
      }
    });
    test('everything else is a generic file', () {
      for (final e in ['pdf', 'zip', 'txt', 'wasm', 'xyz']) {
        expect(MediaRef.classify(e), MediaKind.file, reason: e);
      }
    });
  });
}
