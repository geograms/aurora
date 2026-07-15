import 'package:flutter/material.dart';

/// `$type:"popularity"` — a native monthly bar chart of how many peers held
/// (seeders) and downloaded from (unique leechers) a folder, one grouped pair of
/// bars per month. Read-only; the wapp sets the value (via `ui.field.set`) to a
/// list of `{ym, seeders, leechers}` where `ym = year*100 + month`.
///
/// Native CustomPainter (no webview) — a chart is not a form. The data lives on
/// the device only (never in the folder); this widget just draws it.
class PopularityChartField extends StatelessWidget {
  final List<Map<String, dynamic>> months;
  const PopularityChartField({super.key, required this.months});

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  static const _monNames = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static String _label(int ym) {
    final m = ym % 100;
    if (m < 1 || m > 12) return '$ym';
    return _monNames[m];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final data = months
        .map((m) => (
              ym: _int(m['ym']),
              seeders: _int(m['seeders']),
              leechers: _int(m['leechers']),
            ))
        .where((m) => m.ym > 0)
        .toList();

    if (data.isEmpty) {
      return Container(
        height: 160,
        alignment: Alignment.center,
        child: Text(
          'No popularity yet — it fills in as this torrent is shared.',
          textAlign: TextAlign.center,
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }

    final seedersColor = cs.primary;
    final leechersColor = cs.tertiary;
    final peak = data.fold<int>(
        1, (mx, m) => [mx, m.seeders, m.leechers].reduce((a, b) => a > b ? a : b));
    final peakSeed =
        data.fold<int>(0, (mx, m) => m.seeders > mx ? m.seeders : mx);
    final peakLeech =
        data.fold<int>(0, (mx, m) => m.leechers > mx ? m.leechers : mx);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Legend + headline peaks.
        Row(children: [
          _legendDot(seedersColor),
          const SizedBox(width: 6),
          Text('Seeders', style: tt.bodySmall?.copyWith(color: cs.onSurface)),
          Text('  peak $peakSeed',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(width: 18),
          _legendDot(leechersColor),
          const SizedBox(width: 6),
          Text('Leechers', style: tt.bodySmall?.copyWith(color: cs.onSurface)),
          Text('  peak $peakLeech',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          height: 220,
          child: CustomPaint(
            size: Size.infinite,
            painter: _PopularityPainter(
              data: data,
              peak: peak,
              seedersColor: seedersColor,
              leechersColor: leechersColor,
              gridColor: cs.outlineVariant.withValues(alpha: 0.4),
              labelColor: cs.onSurfaceVariant,
              labelFn: _label,
            ),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color c) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
      );
}

typedef _Month = ({int ym, int seeders, int leechers});

class _PopularityPainter extends CustomPainter {
  final List<_Month> data;
  final int peak;
  final Color seedersColor;
  final Color leechersColor;
  final Color gridColor;
  final Color labelColor;
  final String Function(int ym) labelFn;

  _PopularityPainter({
    required this.data,
    required this.peak,
    required this.seedersColor,
    required this.leechersColor,
    required this.gridColor,
    required this.labelColor,
    required this.labelFn,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const labelH = 18.0; // room for month labels under the axis
    const topPad = 6.0;
    final chartH = size.height - labelH - topPad;
    final chartW = size.width;
    if (chartH <= 0 || chartW <= 0) return;
    final baseY = topPad + chartH;

    // Horizontal gridlines at 0, ½, full of the peak.
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final frac in const [0.0, 0.5, 1.0]) {
      final y = baseY - chartH * frac;
      canvas.drawLine(Offset(0, y), Offset(chartW, y), grid);
      _text(canvas, '${(peak * frac).round()}', Offset(2, y - 12), 9, labelColor);
    }

    final n = data.length;
    final slot = chartW / n; // one month per slot
    final barW = (slot * 0.30).clamp(3.0, 26.0);
    final gap = slot * 0.10;

    final seedPaint = Paint()..color = seedersColor;
    final leechPaint = Paint()..color = leechersColor;

    for (var i = 0; i < n; i++) {
      final m = data[i];
      final cx = slot * i + slot / 2;
      final sH = chartH * (m.seeders / peak);
      final lH = chartH * (m.leechers / peak);
      final sx = cx - barW - gap / 2;
      final lx = cx + gap / 2;
      _bar(canvas, sx, baseY, barW, sH, seedPaint);
      _bar(canvas, lx, baseY, barW, lH, leechPaint);
      // Month label; thin the labels when crowded so they never overlap.
      final step = (n / (chartW / 34)).ceil().clamp(1, n);
      if (i % step == 0) {
        _text(canvas, labelFn(m.ym), Offset(cx - 12, baseY + 4), 10, labelColor);
      }
    }
  }

  void _bar(Canvas c, double x, double baseY, double w, double h, Paint p) {
    if (h <= 0) {
      // Draw a faint 1px stub so a zero month is visibly present, not missing —
      // with its own paint so the shared bar paint's colour is not mutated.
      final stub = Paint()..color = p.color.withValues(alpha: 0.35);
      c.drawRect(Rect.fromLTWH(x, baseY - 1, w, 1), stub);
      return;
    }
    final r = RRect.fromRectAndCorners(
      Rect.fromLTWH(x, baseY - h, w, h),
      topLeft: const Radius.circular(3),
      topRight: const Radius.circular(3),
    );
    c.drawRRect(r, p);
  }

  void _text(Canvas c, String s, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(_PopularityPainter old) =>
      old.data != data ||
      old.peak != peak ||
      old.seedersColor != seedersColor ||
      old.leechersColor != leechersColor;
}
