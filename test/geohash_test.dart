import 'package:aurora/util/geohash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('geohashEncode', () {
    test('matches published reference values', () {
      // Reference vectors from the geohash definition.
      expect(geohashEncode(57.64911, 10.40744, precision: 11),
          'u4pruydqqvj');
      expect(geohashEncode(42.6, -5.6, precision: 5), 'ezs42');
      expect(geohashEncode(0, 0, precision: 6), 's00000');
    });

    test('a shorter hash is a prefix of a longer one at the same place', () {
      // This is what makes truncation a valid way to coarsen, and padding an
      // invalid way to refine.
      final fine = geohashEncode(38.7223, -9.1393, precision: 8);
      for (var n = 1; n < 8; n++) {
        expect(geohashEncode(38.7223, -9.1393, precision: n),
            fine.substring(0, n));
      }
    });

    test('Lisbon does not encode to the Baltic', () {
      // The bug this replaces: Coverage stored the literal 'u0' for every
      // device, so a node in Portugal advertised a region in the Baltic.
      final lisbon = geohashEncode(38.7223, -9.1393, precision: 4);
      expect(lisbon.startsWith('u0'), isFalse);
      expect(lisbon, 'eycs');
    });

    test('southern and western hemispheres encode distinctly', () {
      final sydney = geohashEncode(-33.8688, 151.2093, precision: 5);
      final lisbon = geohashEncode(38.7223, -9.1393, precision: 5);
      expect(sydney, isNot(lisbon));
      expect(sydney, 'r3gx2');
    });

    test('precision below one character yields nothing', () {
      expect(geohashEncode(38.7223, -9.1393, precision: 0), '');
    });
  });

  group('geohashValid', () {
    test('accepts the base-32 alphabet and rejects what it excludes', () {
      expect(geohashValid('ezjmgwrx'), isTrue);
      // a, i, l and o are not in the geohash alphabet.
      expect(geohashValid('aeiou'), isFalse);
      expect(geohashValid('ezjm!'), isFalse);
      expect(geohashValid(''), isFalse);
    });
  });
}
