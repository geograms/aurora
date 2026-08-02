import 'dart:collection';
import 'dart:ui';

/// Screen-space label placement: which labels get drawn, and where.
///
/// A sprite scene projects world positions through a perspective camera, so two
/// nodes that are nowhere near each other in space can land a few pixels apart
/// on screen. Orbs survive that — they are round, they glow, they stack
/// legibly. Text does not: a name is 20-40x the width of the orb it belongs to,
/// so a crowd of orbs is a wall of overlapping words, and the view stops saying
/// anything at all.
///
/// This is the pass that stops it. It is pure geometry over already-measured
/// text, deliberately free of Canvas, so it can be unit-tested: give it
/// candidates, get back the ones that fit and where.

/// One label asking for a place on screen.
class LabelCandidate {
  const LabelCandidate({
    required this.index,
    required this.key,
    required this.anchor,
    required this.corePx,
    required this.size,
    required this.priority,
    required this.depth,
  });

  /// Index into the caller's node/pose lists — passed straight back out.
  final int index;

  /// Stable identity, used to remember which slot this label had last frame.
  /// Two nodes at the same point must not swap labels every frame.
  final String key;

  /// The orb's centre in canvas coordinates.
  final Offset anchor;

  /// The orb's projected core radius, which sets how far the text sits off it.
  final double corePx;

  /// The laid-out text's size. The caller measured it; this pass never does.
  final Size size;

  /// Higher wins a contested spot. See [labelPriorityOf].
  final double priority;

  /// Camera-space depth (negative, more negative = farther). Nearer wins ties.
  final double depth;
}

/// Where one label ended up.
class LabelPlacement {
  const LabelPlacement(this.index, this.topLeft, this.slot);

  final int index;
  final Offset topLeft;

  /// 0 below, 1 above, 2 right, 3 left — carried so the caller can remember it.
  final int slot;
}

/// Padding around a label's box before it counts as touching another.
const double kLabelPadPx = 2.0;

/// Orbs at least this big seed the occupancy map: text over a hub's white-hot
/// core is unreadable whatever else we do. Only the big ones — seeding every
/// orb would block the whole screen in a hundred-node scene.
const double kOrbSeedMinPx = 12.0;

/// How many candidates get the rect test at all. The budget below caps how many
/// are DRAWN; this caps how much work a five-hundred-node scene can ask for.
const int kLabelAttempts = 160;

/// Slot memory, so a label keeps the position it had last frame instead of
/// hopping above/below as the camera drifts. Bounded like the text cache.
final LinkedHashMap<String, int> _slotMemory = LinkedHashMap<String, int>();
const int _kMaxSlotMemory = 600;

int? _rememberedSlot(String key) {
  final v = _slotMemory.remove(key);
  if (v != null) _slotMemory[key] = v;
  return v;
}

void _remember(String key, int slot) {
  _slotMemory.remove(key);
  _slotMemory[key] = slot;
  while (_slotMemory.length > _kMaxSlotMemory) {
    _slotMemory.remove(_slotMemory.keys.first);
  }
}

/// Forget every remembered slot. For tests, and for a scene that was replaced
/// wholesale (the old keys will never be asked for again).
void resetLabelSlots() => _slotMemory.clear();

/// Place as many of [candidates] as fit without overlapping, highest priority
/// first, at most [budget] of them.
///
/// [viewport] is the drawable rect in the SAME coordinates as the anchors — the
/// sprite painter translates its canvas to the centre, so that is `±size/2`.
/// [seeds] are rects already spoken for (bright orb cores).
///
/// The collision test is a linear scan: at a budget of 40 that is ~40x40x4
/// float compares a frame, far under a tenth of a millisecond. It does NOT want
/// a quadtree — if the budget ever passes a couple of hundred, revisit, but
/// until then the flat list is both faster and simpler.
List<LabelPlacement> placeLabels(
  List<LabelCandidate> candidates, {
  required Rect viewport,
  required int budget,
  List<Rect> seeds = const <Rect>[],
}) {
  if (candidates.isEmpty || budget <= 0) return const <LabelPlacement>[];

  final ranked = List<LabelCandidate>.of(candidates)
    ..sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      // Nearer first: a label you can almost touch beats one across the map.
      final d = b.depth.compareTo(a.depth);
      if (d != 0) return d;
      // Deterministic, or coincident nodes trade the surviving label frame to
      // frame and the whole view shimmers.
      return a.key.compareTo(b.key);
    });

  final occupied = List<Rect>.of(seeds);
  final placed = <LabelPlacement>[];
  final attempts =
      ranked.length > kLabelAttempts ? kLabelAttempts : ranked.length;

  for (var i = 0; i < attempts && placed.length < budget; i++) {
    final c = ranked[i];
    final remembered = _rememberedSlot(c.key);
    final order = <int>[
      ?remembered,
      for (var s = 0; s < 4; s++)
        if (s != remembered) s,
    ];

    for (final slot in order) {
      final topLeft = _slotOffset(c, slot);
      final rect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        c.size.width,
        c.size.height,
      ).inflate(kLabelPadPx);
      // FULLY inside, not merely touching: half a name clipped by the window
      // edge is as unreadable as two names on top of each other, and it looks
      // like a bug rather than a boundary.
      if (!_containsRect(viewport.deflate(2), rect)) continue;
      var clash = false;
      for (final r in occupied) {
        if (r.overlaps(rect)) {
          clash = true;
          break;
        }
      }
      if (clash) continue;
      occupied.add(rect);
      placed.add(LabelPlacement(c.index, topLeft, slot));
      _remember(c.key, slot);
      break;
    }
    // No slot fits: drop it. Shrinking the font to make room would just be the
    // same unreadable pile in smaller type.
  }
  return placed;
}

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

/// Top-left of the label box for one slot: 0 below, 1 above, 2 right, 3 left.
Offset _slotOffset(LabelCandidate c, int slot) {
  final gap = c.corePx * 1.15 + 4;
  switch (slot) {
    case 1:
      return c.anchor + Offset(-c.size.width / 2, -(gap + c.size.height));
    case 2:
      return c.anchor + Offset(c.corePx * 1.15 + 6, -c.size.height / 2);
    case 3:
      return c.anchor +
          Offset(-(c.corePx * 1.15 + 6 + c.size.width), -c.size.height / 2);
    default:
      return c.anchor + Offset(-c.size.width / 2, gap);
  }
}

/// The ranking a caller should use unless it has a better idea: what the user
/// pointed at outranks what the scene thinks is important, which outranks
/// what is merely near.
double labelPriorityOf({
  bool selected = false,
  bool hovered = false,
  bool highlighted = false,
  int spritePriority = 0,
  double fade = 1.0,
}) {
  var p = spritePriority * 10.0;
  if (selected) p += 1000;
  if (hovered) p += 500;
  if (highlighted) p += 250;
  // A label that is barely fading in should lose its spot to a solid one.
  return p + fade.clamp(0.0, 1.0);
}
