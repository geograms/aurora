import 'package:flutter_test/flutter_test.dart';

import 'package:aurora/util/blurhash.dart';
import 'package:aurora/util/nostr_imeta.dart';

void main() {
  group('blurhash', () {
    test('decodes the reference hash to plausible pixels', () {
      // The blurha.sh homepage example.
      final px = blurhashPixels('LEHV6nWB2yk8pyo0adR*.7kCMdnj', 16, 16);
      expect(px, isNotNull);
      expect(px!.length, 16 * 16 * 4);
      // Not a flat frame: some variation across pixels.
      final first = px[0];
      expect(px.any((v) => (v - first).abs() > 8), isTrue);
      // Alpha fully opaque.
      for (var i = 3; i < px.length; i += 4) {
        expect(px[i], 255);
      }
    });

    test('rejects malformed input', () {
      expect(blurhashPixels('', 8, 8), isNull);
      expect(blurhashPixels('L', 8, 8), isNull);
      expect(blurhashPixels('LEHV6nWB2yk8pyo0adR*', 8, 8), isNull); // truncated
    });
  });

  group('imeta', () {
    const tags = [
      ['e', 'abc'],
      [
        'imeta',
        'url https://host/v.mp4',
        'm video/mp4',
        'dim 1080x1920',
        'duration 38.6',
        'image https://host/v.jpg',
        'blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj',
      ],
    ];

    test('extracts per-url fields from tags', () {
      final m = imetaFromTags(tags);
      expect(m.keys.single, 'https://host/v.mp4');
      final f = m.values.single;
      expect(f['image'], 'https://host/v.jpg');
      expect(f['dim'], '1080x1920');
      expect(f['dur'], '38.6');
      expect(f['blurhash'], startsWith('LEHV'));
    });

    test('meta JSON round-trips', () {
      final json = imetaMetaJson(tags);
      expect(json, isNotEmpty);
      final back = imetaFromMeta(json);
      expect(back['https://host/v.mp4']?['image'], 'https://host/v.jpg');
    });

    test('empty and garbage meta parse to empty', () {
      expect(imetaFromMeta(null), isEmpty);
      expect(imetaFromMeta(''), isEmpty);
      expect(imetaFromMeta('not json'), isEmpty);
      expect(imetaMetaJson(const [['e', 'x']]), isEmpty);
    });
  });
}
