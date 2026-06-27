// GeneratedAvatar — a deterministic, identicon-style avatar for any
// conversation/person/group. Both the geometric design AND the background
// colour are derived purely from a seed string (the title), with a stable
// hand-rolled hash (NOT String.hashCode, which isn't stable across runs/
// platforms) so the SAME title yields the SAME icon on every install.
//
// The pattern is a 5x5 grid mirrored across the vertical axis (so it always
// looks intentional/symmetric), painted in near-white on a colour drawn from a
// curated palette of medium-dark hues — every one has strong contrast with the
// white pattern, so it stays readable.

import 'package:flutter/material.dart';

// Curated palette: medium-dark, all readable under a white pattern. No pale
// yellows/limes (they wash out white).
const List<Color> _kAvatarPalette = [
  Color(0xFFC62828), Color(0xFFAD1457), Color(0xFF6A1B9A), Color(0xFF4527A0),
  Color(0xFF283593), Color(0xFF1565C0), Color(0xFF0277BD), Color(0xFF00838F),
  Color(0xFF00695C), Color(0xFF2E7D32), Color(0xFF558B2F), Color(0xFF9E6D00),
  Color(0xFFEF6C00), Color(0xFFD84315), Color(0xFF4E342E), Color(0xFF37474F),
];

/// Stable 32-bit hash of [s] (FNV-1a). Deterministic across installs/platforms.
int _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// The background colour generated for [seed] (exposed so callers can match
/// other accents to a conversation's avatar if they want).
Color generatedAvatarColor(String seed) =>
    _kAvatarPalette[_stableHash(seed) % _kAvatarPalette.length];

/// A circular identicon avatar for [seed], [size] px across.
class GeneratedAvatar extends StatelessWidget {
  const GeneratedAvatar({required this.seed, this.size = 44, super.key});
  final String seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(child: CustomPaint(painter: _IdenticonPainter(seed))),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.seed);
  final String seed;

  @override
  void paint(Canvas canvas, Size size) {
    final h = _stableHash(seed);
    final bg = _kAvatarPalette[h % _kAvatarPalette.length];
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    const grid = 5;
    final cell = size.width / grid;
    // Inset the pattern a little so it reads as a centred mark, not edge-to-edge.
    final pad = cell * 0.5;
    final inner = (size.width - pad * 2) / grid;
    final fg = Paint()..color = const Color(0xFFF2F2F2);
    // 15 cells (3 columns x 5 rows); mirror columns 0,1 to 4,3. Bits come from a
    // second hash so the colour and the pattern don't move in lockstep.
    final bits = _stableHash('$seed#pattern');
    var i = 0;
    for (var gx = 0; gx < 3; gx++) {
      for (var gy = 0; gy < grid; gy++) {
        final on = ((bits >> (i % 31)) & 1) == 1;
        i++;
        if (!on) continue;
        for (final col in (gx == 2) ? [2] : [gx, grid - 1 - gx]) {
          final r = Rect.fromLTWH(
              pad + col * inner, pad + gy * inner, inner + 0.5, inner + 0.5);
          canvas.drawRect(r, fg);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) => old.seed != seed;
}
