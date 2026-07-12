/*
 * VideoTimeBar — the thin "how far in / how long" overlay every inline
 * video player shares (hw / native-process / wasm). Tracks a positionMs
 * listenable the player updates and the clip duration when the backend
 * knows it. When the backend can seek (hw MediaPlayer, native ffmpeg
 * restart) it passes [onSeek] and tapping the bar jumps there; the wasm
 * decoder has no seek, so its bar stays display-only.
 */

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class VideoTimeBar extends StatelessWidget {
  final ValueListenable<int> positionMs;
  final int durationMs; // 0 = unknown (position-only label, no fill)
  final void Function(int ms)? onSeek; // null = display-only

  const VideoTimeBar({
    super.key,
    required this.positionMs,
    required this.durationMs,
    this.onSeek,
  });

  static String _fmt(int ms) {
    final s = (ms / 1000).round();
    final m = s ~/ 60, sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final seekable = onSeek != null && durationMs > 0;
    final body = ValueListenableBuilder<int>(
      valueListenable: positionMs,
      builder: (_, pos, __) {
        final frac = durationMs > 0
            ? (pos / durationMs).clamp(0.0, 1.0).toDouble()
            : null;
        final label = durationMs > 0
            ? '${_fmt(pos)} / ${_fmt(durationMs)}'
            : _fmt(pos);
        final bar = ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: frac ?? 0,
            minHeight: seekable ? 5 : 3,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(Color(0xFF8AB4F8)),
          ),
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: seekable
                    ? LayoutBuilder(
                        builder: (_, c) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) {
                            final w = c.maxWidth;
                            if (w <= 0) return;
                            final f = (d.localPosition.dx / w).clamp(0.0, 1.0);
                            onSeek!((f * durationMs).round());
                          },
                          // A little vertical slop so the thin bar is
                          // tappable without pixel-hunting.
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: bar,
                          ),
                        ),
                      )
                    : bar,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
    return seekable ? body : IgnorePointer(child: body);
  }
}
