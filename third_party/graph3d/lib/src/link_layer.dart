import 'package:flutter/rendering.dart';

import 'model.dart';
import 'profile.dart';
import 'scene/pose.dart';
import 'scene/projection.dart';

/// Ball radius in world units, as in the original's `SphereGeometry(5, 5, 5)`.
const double _kBallRadius = 5;

/// Draws the edges behind the cards: a line per edge, an optional ball
/// crawling from source to target, and an optional label at the midpoint.
///
/// Endpoints are projected through the same matrix chain as the cards, so a
/// line meets the card it points at.
class LinkPainter extends CustomPainter {
  LinkPainter({
    required this.edges,
    required this.poses,
    required this.projector,
    required this.clockMs,
    required this.periods,
    required super.repaint,
  });

  final List<SceneEdge> edges;
  final List<Pose> poses;
  final Projector projector;
  final double clockMs;

  /// One crawl period per edge, in milliseconds, so the balls do not march in
  /// lockstep.
  final List<double> periods;

  static final ProfileTimer _timer = ProfileTimer('LINKPAINT');

  /// Label layouts are cached across painter instances: labels are few (edge
  /// interface names) and TextPainter.layout is not free.
  static final Map<String, TextPainter> _labels = <String, TextPainter>{};

  static TextPainter _labelFor(String text, Color color) {
    return _labels.putIfAbsent('$text#${color.toARGB32()}', () {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 11, color: color),
        ),
        textDirection: TextDirection.ltr,
      );
      painter.layout();
      return painter;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (edges.isEmpty) return;
    _timer.time(() => _paintEdges(canvas, size));
  }

  void _paintEdges(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final line = Paint()..isAntiAlias = true;
    final under = Paint()..isAntiAlias = true;
    final ball = Paint();
    final ballHalo = Paint();

    for (var i = 0; i < edges.length; i++) {
      final edge = edges[i];
      if (edge.isSelfEdge) continue;

      final from = poses[edge.from - 1].position;
      final to = poses[edge.to - 1].position;

      final a = projector.project(from);
      final b = projector.project(to);
      // Any endpoint behind the eye would project to a mirrored point, drawing
      // a line across the screen that does not exist.
      if (a == null || b == null) continue;

      final style = edge.style;
      var start = centre + a.screen;
      var end = centre + b.screen;
      Offset shift = Offset.zero;
      if (style.offsetPx != 0) {
        final delta = end - start;
        final length = delta.distance;
        if (length > 1) {
          final normal = Offset(-delta.dy / length, delta.dx / length);
          shift = normal * style.offsetPx;
          start += shift;
          end += shift;
        }
      }

      if (style.glow) {
        // Layered strokes read as bloom without any per-frame blur.
        under
          ..color = style.color.withValues(alpha: style.color.a * 0.18)
          ..strokeWidth = style.width * 4 + 3
          ..strokeCap = StrokeCap.round;
        if (style.dashed) {
          _drawDashed(canvas, start, end, under);
        } else {
          canvas.drawLine(start, end, under);
        }
      }

      line
        ..color = style.color
        ..strokeWidth = style.width;
      if (style.dashed) {
        _drawDashed(canvas, start, end, line);
      } else {
        canvas.drawLine(start, end, line);
      }

      if (style.ticks > 0) {
        _drawTicks(canvas, start, end, style, line);
      }

      final label = style.label;
      if (label != null) {
        final painter = _labelFor(label, style.color);
        final mid = centre + (a.screen + b.screen) / 2;
        painter.paint(
          canvas,
          mid - Offset(painter.width / 2, painter.height + 2),
        );
      }

      if (style.crawler) {
        final period = periods[i];
        for (var pulse = 0; pulse < style.pulseCount; pulse++) {
          final phase =
              ((clockMs / period) + pulse / style.pulseCount) % 1.0;
          final crawler = projector.project(from + (to - from) * phase);
          if (crawler == null) continue;

          final at = centre + crawler.screen + shift;
          final radius = (_kBallRadius * crawler.scale).clamp(1.0, 10.0);
          if (style.glow) {
            ballHalo.color = style.color.withValues(alpha: 0.3);
            canvas.drawCircle(at, radius * 2.4, ballHalo);
          }
          ball.color = style.color;
          canvas.drawCircle(at, radius, ball);
        }
      }
    }
  }

  /// Screen-space dashes by direct segment math — no Path allocation.
  static void _drawDashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 10.0;
    const gap = 7.0;
    final delta = b - a;
    final length = delta.distance;
    if (length < 1) return;
    final direction = delta / length;
    var travelled = 0.0;
    while (travelled < length) {
      final segmentEnd = (travelled + dash).clamp(0.0, length);
      canvas.drawLine(
        a + direction * travelled,
        a + direction * segmentEnd,
        paint,
      );
      travelled += dash + gap;
    }
  }

  /// One small perpendicular mark per unknowable intermediate hop, evenly
  /// spaced along the edge.
  static void _drawTicks(
    Canvas canvas,
    Offset a,
    Offset b,
    EdgeStyle style,
    Paint paint,
  ) {
    final delta = b - a;
    final length = delta.distance;
    if (length < 1) return;
    final direction = delta / length;
    final normal = Offset(-direction.dy, direction.dx);
    for (var t = 1; t <= style.ticks; t++) {
      final at = a + direction * (length * t / (style.ticks + 1));
      canvas.drawLine(at - normal * 5, at + normal * 5, paint);
    }
  }

  @override
  bool shouldRepaint(LinkPainter oldDelegate) => true;

  @override
  bool hitTest(Offset position) => false;
}

/// Assigns each edge the 9-to-11 second crawl the original tweened.
List<double> buildCrawlPeriods(int count, {int seed = 7}) {
  var state = seed;
  double next() {
    // xorshift: deterministic, no dart:math Random needed per call site.
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state & 0xFFFFFF) / 0xFFFFFF;
  }

  return List<double>.generate(count, (_) => next() * 2000 + 9000);
}
