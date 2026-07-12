/*
 * WasmVideoPlayer — an embedded video player widget.
 *
 * Plays a video INLINE wherever it's placed (e.g. inside a chat/stream
 * media thumbnail) by running the installed media player wapp's decoder
 * HEADLESSLY: it loads that wapp's app.wasm into a private WappEngine,
 * hands it the file, pumps its tick loop, and renders the decoded RGBA
 * frames the wapp pushes through the codec-free A/V sink
 * ([WasmVideoSession]). No codec lives in the host.
 *
 * A fullscreen button shows the SAME session enlarged on a black route —
 * the embedded engine keeps decoding behind it, so there's a single
 * decoder and no restart.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../profile/storage_paths.dart';
import '../wapp_engine.dart';
import '../wapp_file_associations.dart';
import 'wasm_audio_output.dart';
import 'wasm_video_session.dart';

/// Handler wapps able to decode HEADLESSLY for the host's codec-free A/V
/// sink: they declare the frame-push HAL (`requires.hal` contains "video",
/// i.e. hal_video_frame). A handler that instead drives a host media backend
/// (e.g. the Movies wapp via the media.video functionality) matches the
/// extension but can never feed this player a frame — filter those out so an
/// installed Movies wapp can't shadow the Player wapp here.
List<WappAssociation> framePushPlayersFor(String ext) =>
    WappFileAssociations.instance
        .lookupForFile('x.$ext', mode: 'view')
        .where((a) => a.manifest.requiredHal.contains('video'))
        .toList();

/// Generates a still poster (the first decoded frame) for a video by running
/// the player wapp's wasm decoder headlessly. Used to show a thumbnail in the
/// stream so people can tell what a clip is about before playing. The result
/// is meant to be cached by the caller (e.g. MediaArchive.setScreenshot), so
/// generation runs once per file. Generations are serialized — the decoder is
/// heavy and we don't want several running at once while scrolling.
class WasmVideoThumbnailer {
  WasmVideoThumbnailer._();

  static Future<void> _queue = Future<void>.value();

  /// Decode the first frame of [media] and return a downscaled PNG, or null on
  /// failure (no player installed, not decodable, etc.). Serialized globally.
  static Future<Uint8List?> generate(Uint8List media, String ext) {
    final result = _queue.then((_) => _generate(media, ext));
    // Keep the chain alive regardless of individual failures.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<Uint8List?> _generate(Uint8List media, String ext) async {
    final matches = framePushPlayersFor(ext);
    if (matches.isEmpty) return null;
    final wasm = await wappPackageStorage(matches.first.manifest.dirPath)
        .readBytes('app.wasm');
    if (wasm == null) return null;

    final dir = await Directory.systemTemp.createTemp('aurora_thumb_');
    final f = File('${dir.path}/v.$ext');
    await f.writeAsBytes(media, flush: true);

    // Scan several frames from the start and keep the most visually
    // interesting one (well-lit, colorful, detailed) — the literal first
    // frame is often black or a fade-in, which makes a dull poster.
    Uint8List? best;
    var fw = 0, fh = 0;
    var bestScore = -1.0;
    var ended = false;
    final engine = WappEngine()
      ..onVideoFrame = (bytes, w, h, fmt, pts) {
        if (fmt != 0 || w <= 0 || h <= 0 || bytes.length < w * h * 4) return;
        final s = _frameScore(bytes, w, h);
        if (s > bestScore) {
          bestScore = s;
          best = bytes;
          fw = w;
          fh = h;
        }
      }
      ..onVideoEnd = () => ended = true;
    try {
      await engine.load(wasm);
      engine.init();
      engine.sendMessage(
          jsonEncode({'type': 'file.open', 'path': f.path, 'mode': 'view'}));
      engine.handleEvent();
      engine.drainOutbox();
      engine.sendMessage(jsonEncode({'type': 'video.scan'}));
      engine.handleEvent();
      engine.drainOutbox();
      // Pump ticks until the scan finishes (cap as a safety net).
      for (var i = 0; i < 600 && !ended; i++) {
        engine.tick();
        engine.drainOutbox();
      }
    } catch (_) {
      // fall through — best may still hold a usable frame
    } finally {
      engine.dispose();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }

    final px = best;
    if (px == null || fw <= 0 || fh <= 0) return null;
    if (px.length < fw * fh * 4) return null;
    return _encodePng(px, fw, fh);
  }

  /// Heuristic "how good a poster is this frame" score: rewards contrast
  /// (detail) and colorfulness, and heavily penalizes near-black, blown-out,
  /// or flat/blank frames (so a fade-in or black intro never wins).
  static double _frameScore(Uint8List rgba, int w, int h) {
    final total = w * h;
    final stride = (total ~/ 3000).clamp(1, 1 << 20);
    var n = 0;
    var sumL = 0.0, sumL2 = 0.0, sumColor = 0.0;
    for (var p = 0; p < total; p += stride) {
      final i = p * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final l = 0.299 * r + 0.587 * g + 0.114 * b;
      sumL += l;
      sumL2 += l * l;
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      sumColor += (mx - mn).toDouble();
      n++;
    }
    if (n == 0) return 0;
    final meanL = sumL / n;
    final varL = (sumL2 / n) - meanL * meanL;
    final stdL = math.sqrt(varL < 0 ? 0 : varL); // contrast / detail
    final colorf = sumColor / n; // colorfulness
    var score = stdL + colorf;
    if (meanL < 22) {
      score *= 0.04; // near-black
    } else if (meanL < 40) {
      score *= 0.5; // dim
    }
    if (meanL > 238) score *= 0.3; // blown out
    if (stdL < 6) score *= 0.3; // flat / solid color
    return score;
  }

  static Future<ui.Image> _toImage(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// Downscale the frame to a thumbnail (keeps the DB small) and PNG-encode it.
  static Future<Uint8List?> _encodePng(Uint8List rgba, int w, int h) async {
    final full = await _toImage(rgba, w, h);
    const maxDim = 360.0;
    final scale =
        (w >= h ? maxDim / w : maxDim / h).clamp(0.0001, 1.0).toDouble();
    final tw = (w * scale).round().clamp(1, w);
    final th = (h * scale).round().clamp(1, h);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      full,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      ui.Paint()..filterQuality = FilterQuality.medium,
    );
    final pic = recorder.endRecording();
    final small = await pic.toImage(tw, th);
    full.dispose();
    pic.dispose();
    final bytes = await small.toByteData(format: ui.ImageByteFormat.png);
    small.dispose();
    return bytes?.buffer.asUint8List();
  }
}

class WasmVideoPlayer extends StatefulWidget {
  /// The encoded media bytes (e.g. the mp4 file contents).
  final Uint8List mediaBytes;

  /// File extension (without dot) — used to resolve the player wapp.
  final String ext;

  final BoxFit fit;

  /// Show the fullscreen button (off when already shown full-size).
  final bool allowFullscreen;

  /// Audio-only media: render an audio player UI (controls + progress) instead
  /// of a video surface; no fullscreen button or poster.
  final bool isAudio;

  /// Optional title shown in the audio UI (e.g. the file name / post text).
  final String? title;

  const WasmVideoPlayer({
    super.key,
    required this.mediaBytes,
    required this.ext,
    this.fit = BoxFit.contain,
    this.allowFullscreen = true,
    this.isAudio = false,
    this.title,
  });

  @override
  State<WasmVideoPlayer> createState() => _WasmVideoPlayerState();
}

class _WasmVideoPlayerState extends State<WasmVideoPlayer> {
  WasmVideoSession? _session;
  WasmAudioOutput? _audioOut;
  WappEngine? _engine;
  Timer? _ticker;
  Directory? _tempDir;
  String _status = 'loading'; // loading | playing | error
  String _err = '';
  // Flipped by the first decoder output (config/frame/pcm). If the decoder
  // stays silent past the timeout, the codec is unsupported — say so instead
  // of leaving a black box.
  bool _sawSignal = false;
  Timer? _decodeTimeout;
  bool _playing = true; // play/pause state (audio UI)
  int _durationMs = 0; // from media.meta (audio UI progress)
  int _lastUiMs = 0; // throttle audio-UI rebuilds

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final matches = framePushPlayersFor(widget.ext);
      if (matches.isEmpty) {
        final anyHandler = WappFileAssociations.instance
            .lookupForFile('x.${widget.ext}', mode: 'view')
            .isNotEmpty;
        _fail(anyHandler
            ? 'No installed player can decode .${widget.ext} files.'
            : 'No media player installed.\nInstall the Player wapp.');
        return;
      }
      final pkg = wappPackageStorage(matches.first.manifest.dirPath);
      final wasm = await pkg.readBytes('app.wasm');
      if (wasm == null) {
        _fail('Player package is missing app.wasm.');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('aurora_vid_');
      final f = File('${dir.path}/v.${widget.ext}');
      await f.writeAsBytes(widget.mediaBytes, flush: true);

      final session = WasmVideoSession();
      final audioOut = WasmAudioOutput();
      // Audio is the master clock when it's actually playing; otherwise the
      // session falls back to its own Stopwatch (video-only).
      session.masterClock =
          () => audioOut.active ? audioOut.playedPosition : null;
      final engine = WappEngine()
        ..onVideoConfig = ((w, h, fmt) {
          _sawSignal = true;
          session.configure(w, h, fmt);
        })
        ..onVideoFrame = ((bytes, w, h, fmt, pts) {
          _sawSignal = true;
          session.pushFrame(bytes, w, h, fmt, pts);
        })
        ..onAudioPcm = ((pcm, rate, ch, fmt, pts) {
          _sawSignal = true;
          audioOut.pushPcm(pcm, rate, ch, fmt, pts);
        })
        ..onVideoEnd = session.markEnded;
      await engine.load(wasm);
      engine.init();
      session.open(f.path, autoplay: true);
      // Hand the decoder the file; it pushes frames on its tick loop.
      engine.sendMessage(
          jsonEncode({'type': 'file.open', 'path': f.path, 'mode': 'view'}));
      engine.handleEvent();
      _consumeOutbox(engine.drainOutbox()); // catch media.meta + video.load echo

      if (!mounted) {
        engine.dispose();
        session.dispose();
        audioOut.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
        return;
      }
      setState(() {
        _session = session;
        _audioOut = audioOut;
        _engine = engine;
        _tempDir = dir;
        _status = 'playing';
      });
      // If the decoder never produces config/frames/pcm, the codec inside the
      // container isn't supported (e.g. HEVC before the player wapp gained
      // it) — fail visibly instead of leaving a silent black box.
      _decodeTimeout = Timer(const Duration(seconds: 8), () {
        if (_sawSignal || !mounted) return;
        _ticker?.cancel();
        _fail("Can't decode this ${widget.isAudio ? 'audio' : 'video'} "
            '(unsupported codec).');
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
        final e = _engine;
        if (e == null) return;
        try {
          e.tick();
          _consumeOutbox(e.drainOutbox());
        } catch (err) {
          debugPrint('WVP: tick trapped: $err');
          _ticker?.cancel(); // a decoder trap — stop pumping
        }
        // Refresh the audio UI progress a few times a second.
        if (widget.isAudio && mounted) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastUiMs >= 300) {
            _lastUiMs = now;
            setState(() {});
          }
        }
      });
    } catch (e) {
      _fail('$e');
    }
  }

  void _fail(String m) {
    if (!mounted) return;
    setState(() {
      _status = 'error';
      _err = m;
    });
  }

  /// Parse messages the wapp sent (media.meta carries the clip duration).
  void _consumeOutbox(List<String> msgs) {
    for (final m in msgs) {
      if (!m.contains('media.meta')) continue;
      try {
        final j = jsonDecode(m) as Map<String, dynamic>;
        if (j['type'] == 'media.meta') {
          final d = (j['durationMs'] as num?)?.toInt() ?? 0;
          if (d > 0 && d != _durationMs) _durationMs = d;
        }
      } catch (_) {}
    }
  }

  void _togglePlay() {
    final e = _engine;
    if (e == null) return;
    setState(() => _playing = !_playing);
    if (_playing) {
      _audioOut?.resume();
      _session?.play();
      e.sendMessage(jsonEncode({'type': 'video.play'}));
    } else {
      _audioOut?.pause();
      _session?.pause();
      e.sendMessage(jsonEncode({'type': 'video.pause'}));
    }
    e.handleEvent();
    _consumeOutbox(e.drainOutbox());
  }

  void _openFullscreen() {
    final s = _session;
    if (s == null) return;
    Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => _FullscreenVideo(session: s),
    ));
  }

  @override
  void dispose() {
    _decodeTimeout?.cancel();
    _ticker?.cancel();
    _engine?.dispose();
    _session?.dispose();
    _audioOut?.dispose();
    try {
      _tempDir?.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_status == 'error') {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(_err,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ),
      );
    }
    if (widget.isAudio) return _buildAudioUi();
    final s = _session;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (s != null)
            s.buildSurface(widget.fit)
          else
            const Center(
              child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (widget.allowFullscreen && s != null)
            Positioned(
              right: 4,
              bottom: 4,
              child: _RoundBtn(
                  icon: Icons.fullscreen, onTap: _openFullscreen),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioUi() {
    final posMs = _audioOut?.playedPosition.inMilliseconds ?? 0;
    final dur = _durationMs;
    final frac =
        (dur > 0) ? (posMs / dur).clamp(0.0, 1.0).toDouble() : 0.0;
    final title = (widget.title != null && widget.title!.trim().isNotEmpty)
        ? widget.title!.trim()
        : 'Audio';
    return Container(
      color: const Color(0xFF1A1A24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _RoundBtn(
            icon: _playing ? Icons.pause : Icons.play_arrow,
            onTap: _togglePlay,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.audiotrack,
                        color: Colors.white60, size: 14),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: dur > 0 ? frac : null,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF8AB4F8)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  dur > 0
                      ? '${_fmt(posMs)} / ${_fmt(dur)}'
                      : _fmt(posMs),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }
}

/// Fullscreen view of an already-running session (same decoder, no restart).
class _FullscreenVideo extends StatelessWidget {
  final WasmVideoSession session;
  const _FullscreenVideo({required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(child: session.buildSurface(BoxFit.contain)),
            Positioned(
              left: 6,
              top: 6,
              child: _RoundBtn(
                  icon: Icons.close,
                  onTap: () => Navigator.of(context).pop()),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}
