import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../model.dart';
import '../profile.dart';
import 'pose.dart';
import 'projection.dart';

/// Draws every card except the live ones (selected, hovered) as one textured
/// quad each, depth-sorted, in a single picture.
///
/// This replaces a Stack of hundreds of `Transform`ed widgets. Under a
/// perspective transform Flutter cannot cache a widget's raster, so the
/// widget approach re-drew every glyph of every card on every animated frame
/// — a 20-30ms raster bill on a low-end phone. Baked images raster as plain
/// quads.
class CardCrowdPainter extends CustomPainter {
  CardCrowdPainter({
    required this.poses,
    required this.images,
    required this.projector,
    required this.emphasisOf,
    required this.fadeOf,
    required this.skip,
    this.style = const GraphStyle(),
  });

  final List<Pose> poses;

  /// One image per pose, assembled by the view from the [CardBakery].
  final List<ui.Image> images;

  final Projector projector;

  /// Emphasis for the node id (one-based index + 1).
  final CardEmphasis Function(int id) emphasisOf;

  /// Enter/exit opacity for the node id: 1 for settled nodes, ramping for
  /// nodes flying in or out of the scene.
  final double Function(int id) fadeOf;

  /// Node ids drawn as live widgets on top; the crowd must not double-draw
  /// them underneath.
  final Set<int> skip;

  final GraphStyle style;

  static final ProfileTimer _timer = ProfileTimer('CROWDPAINT');

  static final Rect _cardRect = Rect.fromCenter(
    center: Offset.zero,
    width: kCardWidth,
    height: kCardHeight,
  );

  @override
  void paint(Canvas canvas, Size size) {
    _timer.time(() => _paintCrowd(canvas, size));
  }

  void _paintCrowd(Canvas canvas, Size size) {
    final visible = <(int, double)>[];
    for (var i = 0; i < poses.length; i++) {
      final depth = projector.depthOf(poses[i].position);
      if (depth > -1) continue; // behind, or level with, the eye
      visible.add((i, depth));
    }
    // Most negative depth is farthest away, so it gets painted first.
    visible.sort((a, b) => a.$2.compareTo(b.$2));

    final centre = Offset(size.width / 2, size.height / 2);
    final imagePaint = Paint()..filterQuality = FilterQuality.low;
    final highlightPaint = Paint()
      ..color = style.highlightBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    for (final (index, _) in visible) {
      final id = index + 1;
      if (skip.contains(id)) continue;

      final fade = fadeOf(id);
      if (fade <= 0) continue;

      final emphasis = emphasisOf(id);
      // Inactive cards are a ghost of themselves, out of the way of whatever
      // has the user's attention.
      final alpha =
          (emphasis == CardEmphasis.inactive ? style.inactiveAlpha : 1.0) *
          fade;
      imagePaint.color = Color.fromRGBO(255, 255, 255, alpha);

      final image = images[index];
      canvas.save();
      canvas.transform(projector.cardMatrix(poses[index].matrix).storage);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        _cardRect,
        imagePaint,
      );
      if (emphasis == CardEmphasis.highlighted) {
        highlightPaint.color = style.highlightBorder.withValues(
          alpha: style.highlightBorder.a * fade,
        );
        canvas.drawRect(_cardRect, highlightPaint);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CardCrowdPainter oldDelegate) => true;

  @override
  bool hitTest(Offset position) => false;
}

/// The node id under [position] (local to the scene, origin top-left), or
/// null. Front-to-back through the projected card footprints, with the ids in
/// [onTop] tested first — they are drawn above everything, whatever their
/// depth, so they must win the pick too.
int? pickCard({
  required List<Pose> poses,
  required Projector projector,
  required Size size,
  required Offset position,
  Iterable<int> onTop = const <int>[],
}) {
  final point = position - Offset(size.width / 2, size.height / 2);

  for (final id in onTop) {
    if (_hitsCard(poses[id - 1], projector, point)) return id;
  }

  final visible = <(int, double)>[];
  for (var i = 0; i < poses.length; i++) {
    final depth = projector.depthOf(poses[i].position);
    if (depth > -1) continue;
    visible.add((i, depth));
  }
  // Nearest first: the card drawn last is the one the pointer touches.
  visible.sort((a, b) => b.$2.compareTo(a.$2));

  final skip = onTop.toSet();
  for (final (index, _) in visible) {
    if (skip.contains(index + 1)) continue;
    if (_hitsCard(poses[index], projector, point)) return index + 1;
  }
  return null;
}

bool _hitsCard(Pose pose, Projector projector, Offset point) {
  const halfW = kCardWidth / 2;
  const halfH = kCardHeight / 2;
  final model = pose.matrix;

  final corners = <Offset>[];
  for (final local in const <(double, double)>[
    (-halfW, -halfH),
    (halfW, -halfH),
    (halfW, halfH),
    (-halfW, halfH),
  ]) {
    final world = model.transform3(Vector3(local.$1, local.$2, 0));
    final projected = projector.project(world);
    // A corner behind the eye makes the quad unpickable rather than wrong.
    if (projected == null) return false;
    corners.add(projected.screen);
  }

  // Inside a convex quad when the point sits on the same side of all edges.
  double? sign;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final cross =
        (b.dx - a.dx) * (point.dy - a.dy) - (b.dy - a.dy) * (point.dx - a.dx);
    if (cross.abs() < 1e-9) continue;
    if (sign == null) {
      sign = cross.sign;
    } else if (cross.sign != sign) {
      return false;
    }
  }
  return sign != null;
}
