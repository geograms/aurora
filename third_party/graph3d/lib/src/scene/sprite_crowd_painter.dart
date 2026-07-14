import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../model.dart';
import '../profile.dart';
import 'pose.dart';
import 'projection.dart';
import 'sprite.dart';

/// Draws every node as a screen-facing glow orb: one cached radial-gradient
/// circle per node, plus optional rings, badges and level-of-detail labels.
///
/// Measured on an Oukitel C61: 550 full-size gradient orbs raster in ~15ms
/// (68fps); with the halo level-of-detail below they cost flat-circle prices
/// (~6ms) whenever a crowd is far away. There are no textures and no blurs —
/// the glow IS the gradient — so nothing here fights the raster cache.
class SpriteCrowdPainter<T> extends CustomPainter {
  SpriteCrowdPainter({
    required this.poses,
    required this.nodes,
    required this.spriteOf,
    required this.projector,
    required this.emphasisOf,
    required this.fadeOf,
    this.fog = const FogStyle(),
    this.fogNear = -1,
    this.fogFar = -1,
    this.style = const GraphStyle(),
  });

  final List<Pose> poses;
  final List<SceneNode<T>> nodes;
  final NodeSprite Function(SceneNode<T> node) spriteOf;
  final Projector projector;
  final CardEmphasis Function(int id) emphasisOf;
  final double Function(int id) fadeOf;
  final FogStyle fog;

  /// Camera-space depths bounding the scene, for the fog ramp.
  final double fogNear;
  final double fogFar;

  final GraphStyle style;

  /// Below this projected core radius the halo is skipped: a distant node is
  /// a flat star, not a big transparent gradient — that is both the look and
  /// the fill-rate save.
  static const double kHaloMinPx = 4;

  /// Labels and badges only make sense when the orb is big enough to anchor
  /// them.
  static const double kLabelMinPx = 9;
  static const double kBadgeMinPx = 11;

  /// At most this many labels per frame, nearest first. A 500-node cluster
  /// stays a field of lights, not a wall of text.
  static const int kLabelBudget = 40;

  static final ProfileTimer _timer = ProfileTimer('SPRITEPAINT');

  /// One gradient per colour, in unit space; scaled per node by the canvas.
  static final Map<int, Paint> _orbPaints = <int, Paint>{};

  static Paint _orbPaint(Color color) =>
      _orbPaints.putIfAbsent(color.toARGB32(), () {
        return Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(
            Offset.zero,
            1.0,
            <Color>[
              const Color(0xFFFFFFFF),
              color,
              color.withValues(alpha: 0.35),
              color.withValues(alpha: 0.0),
            ],
            const <double>[0.0, 0.16, 0.35, 1.0],
          );
      });

  /// Bounded, because node names are a crowd, not a fixed vocabulary.
  static final LinkedHashMap<String, TextPainter> _texts =
      LinkedHashMap<String, TextPainter>();
  static const int _kMaxTexts = 600;

  static TextPainter _text(String text, double fontSize, Color color) {
    final key = '$text#$fontSize#${color.toARGB32()}';
    final cached = _texts.remove(key);
    if (cached != null) {
      _texts[key] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);
    _texts[key] = painter;
    while (_texts.length > _kMaxTexts) {
      _texts.remove(_texts.keys.first);
    }
    return painter;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _timer.time(() => _paint(canvas, size));
  }

  void _paint(Canvas canvas, Size size) {
    final visible = <(int, double)>[];
    for (var i = 0; i < poses.length; i++) {
      final depth = projector.depthOf(poses[i].position);
      if (depth > -1) continue; // behind, or level with, the eye
      visible.add((i, depth));
    }
    // Far to near: glows stack naturally, labels can take the nearest tail.
    visible.sort((a, b) => a.$2.compareTo(b.$2));

    final centre = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(centre.dx, centre.dy);

    final flatPaint = Paint();
    final ringPaint = Paint()..style = PaintingStyle.stroke;
    final labelled = <(int, Offset, double, double)>[]; // index, pos, corePx, alpha

    for (final (index, depth) in visible) {
      final id = index + 1;
      final fade = fadeOf(id);
      if (fade <= 0) continue;

      final sprite = spriteOf(nodes[index]);
      final projected = projector.project(poses[index].position)!;
      // Distant nodes stay visible as faint stars rather than popping out.
      final corePx = (sprite.radius * projected.scale).clamp(2.5, 400.0);

      final emphasis = emphasisOf(id);
      var alpha = fade;
      if (emphasis == CardEmphasis.inactive) alpha *= style.inactiveAlpha;
      if (fog.enabled) alpha *= fogAlpha(depth, fogNear, fogFar, fog.minAlpha);
      if (alpha <= 0.01) continue;

      final selected = emphasis == CardEmphasis.selected;
      final highlighted = emphasis == CardEmphasis.highlighted;
      final haloScale =
          sprite.haloScale * (selected ? 1.5 : (highlighted ? 1.2 : 1.0));

      if (corePx >= kHaloMinPx) {
        final paint = _orbPaint(sprite.coreColor)
          ..color = Color.fromRGBO(255, 255, 255, alpha.clamp(0.0, 1.0));
        canvas.save();
        canvas.translate(projected.screen.dx, projected.screen.dy);
        canvas.scale(corePx * haloScale);
        canvas.drawCircle(Offset.zero, 1, paint);
        canvas.restore();
      } else {
        flatPaint.color = sprite.coreColor.withValues(alpha: alpha);
        canvas.drawCircle(projected.screen, corePx, flatPaint);
      }

      if (sprite.ringColor != null && corePx >= kHaloMinPx) {
        ringPaint
          ..color = sprite.ringColor!.withValues(alpha: alpha * 0.9)
          ..strokeWidth = (corePx * 0.09).clamp(1.0, 3.0);
        canvas.drawCircle(projected.screen, corePx * 1.35, ringPaint);
      }
      if (sprite.secondaryColor != null && corePx >= kHaloMinPx) {
        ringPaint
          ..color = sprite.secondaryColor!.withValues(alpha: alpha)
          ..strokeWidth = (corePx * 0.18).clamp(1.5, 5.0);
        canvas.drawCircle(projected.screen, corePx * 1.7, ringPaint);
      }

      if (sprite.badge != null &&
          corePx >= (sprite.badgeMinPx ?? kBadgeMinPx)) {
        // A dark pill keeps the count readable over the orb's bright core.
        final badge = _text(
          sprite.badge!,
          (corePx * 0.55).clamp(10.0, 24.0),
          Color.fromRGBO(255, 255, 255, (alpha * 0.95).clamp(0.0, 1.0)),
        );
        final pill = Rect.fromCenter(
          center: projected.screen,
          width: badge.width + 10,
          height: badge.height + 4,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(pill, Radius.circular(pill.height / 2)),
          Paint()
            ..color = Color.fromRGBO(0, 10, 14, (alpha * 0.72).clamp(0.0, 1.0)),
        );
        badge.paint(
          canvas,
          projected.screen - Offset(badge.width / 2, badge.height / 2),
        );
      }

      if (sprite.label != null &&
          corePx >= (sprite.labelMinPx ?? kLabelMinPx)) {
        labelled.add((index, projected.screen, corePx, alpha));
      }
    }

    // Nearest labels win the budget; the list is already far-to-near.
    final start = labelled.length > kLabelBudget
        ? labelled.length - kLabelBudget
        : 0;
    for (var i = start; i < labelled.length; i++) {
      final (index, screen, corePx, alpha) = labelled[i];
      final sprite = spriteOf(nodes[index]);
      final painter = _text(
        sprite.label!,
        11,
        Color.fromRGBO(214, 245, 250, (alpha * 0.85).clamp(0.0, 1.0)),
      );
      painter.paint(
        canvas,
        screen + Offset(-painter.width / 2, corePx * 1.15 + 4),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(SpriteCrowdPainter<T> oldDelegate) => true;

  @override
  bool hitTest(Offset position) => false;
}

/// The node id under [position] in sprite mode, or null: distance to the
/// projected centre against the projected core radius, floored at
/// [minTapRadiusPx] so small orbs stay tappable with a finger. Ids in [onTop]
/// win first, then nearest-first — the same semantics as `pickCard`.
int? pickSprite({
  required List<Pose> poses,
  required double Function(int index) radiusOf,
  required Projector projector,
  required Size size,
  required Offset position,
  double minTapRadiusPx = 24,
  Iterable<int> onTop = const <int>[],
}) {
  final point = position - Offset(size.width / 2, size.height / 2);

  bool hits(int index) {
    final depth = projector.depthOf(poses[index].position);
    if (depth > -1) return false;
    final projected = projector.project(poses[index].position)!;
    final radius = (radiusOf(index) * projected.scale).clamp(2.5, 400.0);
    return (point - projected.screen).distance <=
        (radius > minTapRadiusPx ? radius : minTapRadiusPx);
  }

  for (final id in onTop) {
    if (hits(id - 1)) return id;
  }

  final visible = <(int, double)>[];
  for (var i = 0; i < poses.length; i++) {
    final depth = projector.depthOf(poses[i].position);
    if (depth > -1) continue;
    visible.add((i, depth));
  }
  // Nearest first: the orb drawn last is the one the pointer touches.
  visible.sort((a, b) => b.$2.compareTo(a.$2));

  final skip = onTop.toSet();
  for (final (index, _) in visible) {
    if (skip.contains(index + 1)) continue;
    if (hits(index)) return index + 1;
  }
  return null;
}
