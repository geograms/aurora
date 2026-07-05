/*
 * mesh_bloom — the beacon have-digest (docs/mesh.md §3, M2).
 *
 * A fixed 128-byte Bloom filter over the `am:` correlation ids this node has
 * RECEIVED recently (~24 h window). Carried in the route beacon's reserved
 * `have` field; custodians purge any parked message whose am matches, and
 * skip handing anything in the target's have-set.
 *
 * The filter must be bit-identical between Dart and C (blemesh_session.c),
 * so the hash is plain FNV-1a 32-bit seeded with 4 fixed salt bytes — no
 * platform hash, no crypto dependency:
 *
 *   bit_i = fnv1a32([salt_i] + ascii(am)) % 1024,  salt = 00 55 AA FF
 *
 * k=4 over m=1024 bits holds ~150 ams at <1% false-positive rate; a false
 * positive only suppresses one redundant resend (end-to-end retransmit
 * covers it), so the filter can run well past that comfortably.
 */
import 'dart:typed_data';

const int kMeshBloomBytes = 128;
const List<int> _salts = [0x00, 0x55, 0xAA, 0xFF];

int _fnv1a32(int salt, List<int> data) {
  var h = 0x811C9DC5;
  h ^= salt;
  h = (h * 0x01000193) & 0xFFFFFFFF;
  for (final b in data) {
    h ^= b & 0xFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Set the 4 bits for one am id in [bloom] (must be kMeshBloomBytes long).
void meshBloomAdd(Uint8List bloom, String am) {
  final bytes = am.codeUnits;
  for (final s in _salts) {
    final bit = _fnv1a32(s, bytes) % (kMeshBloomBytes * 8);
    bloom[bit >> 3] |= 1 << (bit & 7);
  }
}

/// True when [am] is possibly in [bloom] (definite no when false).
bool meshBloomHas(Uint8List bloom, String am) {
  if (bloom.length < kMeshBloomBytes) return false;
  final bytes = am.codeUnits;
  for (final s in _salts) {
    final bit = _fnv1a32(s, bytes) % (kMeshBloomBytes * 8);
    if (bloom[bit >> 3] & (1 << (bit & 7)) == 0) return false;
  }
  return true;
}

/// Build a fresh filter from a set of am ids.
Uint8List meshBloomBuild(Iterable<String> ams) {
  final b = Uint8List(kMeshBloomBytes);
  for (final am in ams) {
    meshBloomAdd(b, am);
  }
  return b;
}
