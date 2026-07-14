import 'dart:math' as math;

import 'package:flutter/material.dart';

/// `$type:"stats"` — a native dashboard grid, because statistics are not a
/// form (docs/NOSTR.md, the Indexer UI).
///
/// GeoUI's only stat display used to be a read-only text field, which renders
/// as exactly what it is: an input box someone disabled. A dashboard needs the
/// number to be the biggest thing on the tile and the label to whisper. This
/// widget is that, and nothing else — no interaction except an optional tap id,
/// no state, one cheap CustomPaint per sparkline.
///
/// Fed by `ui.stats.set {field, tiles:[...]}`; each tile:
///   {id, label, value, unit?, hint?, spark?: [numbers], progress?: 0..1,
///    alert?: bool, tap?: bool}
///
/// A tile with `tap:true` fires `<field>_tap` with `<field>_id` = its id, the
/// same contract the people rows use.
class StatsGridField extends StatelessWidget {
  final List<Map<String, dynamic>> tiles;
  final void Function(String id)? onTap;

  const StatsGridField({super.key, required this.tiles, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) {
      return const SizedBox(height: 8);
    }
    return LayoutBuilder(builder: (context, constraints) {
      // Two columns on a phone, more on a wide window. Tiles with a sparkline
      // get the full row — a chart squeezed into half a column is decoration,
      // not information.
      final cols = math.max(2, (constraints.maxWidth / 220).floor());
      final gap = 10.0;
      final cellW = (constraints.maxWidth - gap * (cols - 1)) / cols;

      final children = <Widget>[];
      for (final t in tiles) {
        final wide = t['spark'] is List && (t['spark'] as List).isNotEmpty;
        children.add(SizedBox(
          width: wide ? constraints.maxWidth : cellW,
          child: _StatTile(tile: t, onTap: onTap),
        ));
      }
      return Wrap(spacing: gap, runSpacing: gap, children: children);
    });
  }
}

class _StatTile extends StatelessWidget {
  final Map<String, dynamic> tile;
  final void Function(String id)? onTap;

  const _StatTile({required this.tile, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final alert = tile['alert'] == true;
    final label = '${tile['label'] ?? ''}';
    final value = '${tile['value'] ?? ''}';
    final unit = '${tile['unit'] ?? ''}';
    final hint = '${tile['hint'] ?? ''}';
    final spark = (tile['spark'] as List?)
        ?.map((e) => (e is num) ? e.toDouble() : 0.0)
        .toList();
    final progress = tile['progress'];
    final tappable = tile['tap'] == true && onTap != null;

    final valueColor = alert ? cs.error : cs.onSurface;

    final body = Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: alert
              ? cs.error.withAlpha(120)
              : cs.outlineVariant.withAlpha(80),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: valueColor,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          if (spark != null && spark.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparklinePainter(
                  points: spark,
                  color: alert ? cs.error : cs.primary,
                  fill: (alert ? cs.error : cs.primary).withAlpha(28),
                ),
              ),
            ),
          ],
          if (progress is num) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.toDouble().clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: cs.surfaceContainerHighest,
                color: alert ? cs.error : cs.primary,
              ),
            ),
          ],
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );

    if (!tappable) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onTap!('${tile['id'] ?? ''}'),
      child: body,
    );
  }
}

/// A polyline over ≤48 points with a soft fill. Painting this costs less than
/// the text above it; no isolate, no animation, nothing to schedule.
class _SparklinePainter extends CustomPainter {
  final List<double> points;
  final Color color;
  final Color fill;

  _SparklinePainter({
    required this.points,
    required this.color,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) {
      // One point is a level, not a line.
      final y = size.height / 2;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = color.withAlpha(140)
          ..strokeWidth = 2,
      );
      return;
    }
    final maxV = points.reduce(math.max);
    final minV = points.reduce(math.min);
    final span = (maxV - minV) == 0 ? 1.0 : (maxV - minV);
    final dx = size.width / (points.length - 1);
    // 2px headroom top and bottom so the stroke never clips.
    double yOf(double v) =>
        2 + (size.height - 4) * (1 - (v - minV) / span);

    final line = Path()..moveTo(0, yOf(points[0]));
    for (var i = 1; i < points.length; i++) {
      line.lineTo(dx * i, yOf(points[i]));
    }

    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points || old.color != color;
}
