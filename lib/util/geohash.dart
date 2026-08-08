/// Geohash encoding, standard base-32 alphabet.
///
/// Used for the node coverage region: a deliberately coarse statement of where
/// a node is useful, carried in its announce. Coarseness is the privacy
/// control, so the encoder takes the precision as a parameter and the caller
/// never stores more characters than it intends to publish.
///
/// Reference: https://en.wikipedia.org/wiki/Geohash
library;

const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Encode [latitude]/[longitude] to a geohash of [precision] characters.
///
/// A geohash is coarsened by dropping trailing characters, never by padding:
/// each character narrows the box, so 'ezjm' contains 'ezjmg'. Padding a short
/// hash with '0' does not make it more precise, it names a different place, so
/// a caller wanting more precision must re-encode from the coordinates.
String geohashEncode(double latitude, double longitude, {int precision = 6}) {
  if (precision < 1) return '';
  var latMin = -90.0, latMax = 90.0;
  var lonMin = -180.0, lonMax = 180.0;
  var isLon = true;
  var bit = 0;
  var ch = 0;
  final out = StringBuffer();

  while (out.length < precision) {
    if (isLon) {
      final mid = (lonMin + lonMax) / 2;
      if (longitude >= mid) {
        ch |= 1 << (4 - bit);
        lonMin = mid;
      } else {
        lonMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (latitude >= mid) {
        ch |= 1 << (4 - bit);
        latMin = mid;
      } else {
        latMax = mid;
      }
    }
    isLon = !isLon;
    bit++;
    if (bit == 5) {
      out.write(_base32[ch]);
      bit = 0;
      ch = 0;
    }
  }
  return out.toString();
}

/// True if [s] is a syntactically valid geohash (non-empty, alphabet only).
bool geohashValid(String s) {
  if (s.isEmpty) return false;
  for (final c in s.toLowerCase().codeUnits) {
    if (!_base32.codeUnits.contains(c)) return false;
  }
  return true;
}
