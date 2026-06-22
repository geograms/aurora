/*
 * WasmVideoSession — the host-side, codec-free render sink for video
 * decoded INSIDE a wapp.
 *
 * The companion to media_capability.dart: where MediaCapabilities is the
 * install gate (the `media.video` capability), this is the actual
 * backend. It contains NO codec and NO platform plugin — only dart:ui.
 * A media wapp (e.g. mp4player) decodes frames in WebAssembly and pushes
 * raw RGBA through the engine's hal_video_frame import; WappPage wires
 * that import to [pushFrame] here, which uploads the pixels to a
 * ui.Image and paints them via RawImage.
 *
 * Timing: each frame carries a presentation timestamp (pts_ms). A
 * Stopwatch playback clock (started on play()) gates display so the wapp
 * can decode ahead of real time; frames that fall behind the clock are
 * dropped. If the decoder is slower than real time, frames are simply
 * shown as they arrive (decoder-paced) — playback slows but stays
 * smooth. Audio (PCM) is accepted but dropped in this MVP (raw PCM out
 * is an inherently platform-specific sink — a deliberate follow-up).
 */

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'media_capability.dart';

/// Backend factory registered with [MediaCapabilities] at startup. It
/// pulls in no codec, so registering it unconditionally is safe — video
/// only lights up when a wapp advertising `media.video` is installed.
class WasmVideoBackend implements MediaVideoBackend {
  @override
  List<String> get supportedPlatforms =>
      const ['linux', 'windows', 'macos', 'android', 'ios'];

  @override
  MediaSession createSession() => WasmVideoSession();
}

/// One playing surface fed by a wasm decoder. Pixel formats: 0 = RGBA8888
/// (the only format rendered here; the wapp converts YUV->RGBA itself so
/// the host stays dumb).
class WasmVideoSession implements MediaSession {
  static const int _pixfmtRgba8888 = 0;

  /// Cap on buffered (not-yet-displayed) frames. The wasm decoder paces
  /// itself, but this bounds memory if it runs ahead. Oldest is dropped.
  static const int _maxQueue = 6;

  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  /// Playback clock: elapsed playing time. Frames are due when their
  /// pts_ms <= clock.elapsedMilliseconds.
  final Stopwatch _clock = Stopwatch();

  /// Optional A/V master clock. When set and non-null, video frames are gated
  /// against this (the audio playback position) instead of [_clock], so video
  /// stays in sync with audio. Returns null when there's no audio playing
  /// (video-only) — then [_clock] is used.
  Duration? Function()? masterClock;

  final List<_PendingFrame> _queue = [];
  Timer? _pump;
  bool _decoding = false; // a decodeImageFromPixels is in flight
  bool _disposed = false;

  WasmVideoSession() {
    // ~120Hz pump: cheap, and keeps presentation latency low without
    // coupling to the decode rate.
    _pump = Timer.periodic(const Duration(milliseconds: 8), (_) => _drain());
  }

  // ── Engine import sinks (wired by WappPage) ──────────────────────────

  /// hal_video_config — geometry announce. Kept for future use (surface
  /// sizing is derived per-frame from the ui.Image, so this is a no-op
  /// today beyond documenting intent).
  void configure(int width, int height, int pixfmt) {}

  /// hal_video_frame — one decoded frame from the wapp's wasm decoder.
  void pushFrame(Uint8List rgba, int width, int height, int pixfmt, int ptsMs) {
    if (_disposed) return;
    if (pixfmt != _pixfmtRgba8888) return; // only RGBA8888 supported
    if (width <= 0 || height <= 0) return;
    if (rgba.length < width * height * 4) return; // malformed — skip
    _queue.add(_PendingFrame(rgba, width, height, ptsMs));
    while (_queue.length > _maxQueue) {
      _queue.removeAt(0); // drop oldest under backpressure
    }
  }

  /// hal_audio_pcm — accepted but dropped in the MVP (see file header).
  void pushAudio(
      Uint8List pcm, int sampleRate, int channels, int sampfmt, int ptsMs) {}

  /// hal_video_end — decoder reached the last frame.
  void markEnded() {
    // Let whatever is queued finish; stop the clock so the final frame
    // stays on screen.
    // (No-op for now; the surface simply holds the last image.)
  }

  // ── Frame pump ───────────────────────────────────────────────────────

  void _drain() {
    if (_disposed || _decoding || _queue.isEmpty) return;
    if (!_clock.isRunning) {
      // Paused/not started: still show the first frame so the user sees
      // something, but don't advance.
      if (_frame.value == null) {
        _present(_queue.removeAt(0));
      }
      return;
    }
    // Gate against the audio master clock when audio is playing, else the
    // local Stopwatch.
    final master = masterClock?.call();
    final now = master?.inMilliseconds ?? _clock.elapsedMilliseconds;
    // Find the newest frame whose pts is due; drop older due frames.
    _PendingFrame? due;
    while (_queue.isNotEmpty && _queue.first.ptsMs <= now) {
      due = _queue.removeAt(0);
    }
    if (due != null) _present(due);
  }

  void _present(_PendingFrame f) {
    _decoding = true;
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      (img) {
        _decoding = false;
        if (_disposed) {
          img.dispose();
          return;
        }
        final old = _frame.value;
        _frame.value = img;
        old?.dispose();
      },
    );
  }

  // ── MediaSession ─────────────────────────────────────────────────────

  @override
  Widget buildSurface(BoxFit fit) {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: _frame,
      builder: (context, img, _) {
        if (img == null) {
          return const SizedBox.expand();
        }
        return SizedBox.expand(
          child: FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: img.width.toDouble(),
              height: img.height.toDouble(),
              child: RawImage(image: img, fit: BoxFit.fill),
            ),
          ),
        );
      },
    );
  }

  @override
  void open(String path, {bool autoplay = true}) {
    // Not a decode: the path is delivered to the wasm decoder through the
    // existing video.load message path. Here we just reset playback state
    // for the new stream.
    _queue.clear();
    _clock
      ..reset()
      ..stop();
    final old = _frame.value;
    _frame.value = null;
    old?.dispose();
    if (autoplay) _clock.start();
  }

  @override
  void play() {
    if (!_clock.isRunning) _clock.start();
  }

  @override
  void pause() {
    if (_clock.isRunning) _clock.stop();
  }

  @override
  void stop() {
    _clock
      ..reset()
      ..stop();
    _queue.clear();
    final old = _frame.value;
    _frame.value = null;
    old?.dispose();
  }

  @override
  void seek(Duration position) {
    // Clock-side seek. A precise seek also needs the wapp to re-decode
    // from the target keyframe (delivered via the existing video.seek
    // message); this keeps the host clock in step. Drop stale frames.
    _queue.clear();
    final was = _clock.isRunning;
    _clock.reset();
    // Stopwatch can't be set; emulate an offset by tracking it ourselves
    // would add state — for the MVP we restart timing at the seek point
    // and rely on the wapp to resend frames from there.
    if (was) _clock.start();
  }

  @override
  void skip(Duration delta) {
    // Same caveat as seek(): the wapp re-decodes via video.skip; we just
    // clear buffered frames so the new ones display promptly.
    _queue.clear();
  }

  @override
  void setSubtitle(String path) {
    // No subtitle renderer in the MVP.
  }

  @override
  void dispose() {
    _disposed = true;
    _pump?.cancel();
    _pump = null;
    _queue.clear();
    final old = _frame.value;
    _frame.value = null;
    old?.dispose();
    _frame.dispose();
  }
}

class _PendingFrame {
  final Uint8List rgba;
  final int width;
  final int height;
  final int ptsMs;
  _PendingFrame(this.rgba, this.width, this.height, this.ptsMs);
}
