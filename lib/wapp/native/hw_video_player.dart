/*
 * HwVideoPlayer — inline video via the OS's own hardware decoder.
 *
 * Android only: android.media.MediaPlayer (MediaCodec underneath) renders
 * into a Flutter Texture registered by the HwVideo Kotlin plugin. No codec
 * ships in the app; the phone's dedicated decode silicon does the work, so
 * 1080p+ HEVC plays at full rate with near-zero CPU — the wasm decoder path
 * stays as the fallback for files MediaPlayer rejects (the dispatcher in
 * inline_video_player.dart handles the swap via [onFailed]).
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/log_service.dart';
import 'video_keys.dart';
import 'video_time_bar.dart';

void _log(String line) => LogService.instance.add('[wvp] $line');

/// Thin wrapper over the `com.geogram.aurora/hwvideo` channel.
class HwVideoController {
  static const _ch = MethodChannel('com.geogram.aurora/hwvideo');
  static const _evCh = EventChannel('com.geogram.aurora/hwvideo_events');
  static Stream<Map<dynamic, dynamic>>? _events;

  /// Shared broadcast stream of player events; filter by `id`.
  static Stream<Map<dynamic, dynamic>> events() =>
      _events ??= _evCh.receiveBroadcastStream().map((e) => e as Map);

  int id = -1;
  int textureId = -1;

  Future<void> create(String path) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('create', {
      'path': path,
    });
    id = (r!['id'] as num).toInt();
    textureId = (r['textureId'] as num).toInt();
  }

  Future<void> play() => _ch.invokeMethod('play', {'id': id});
  Future<void> pause() => _ch.invokeMethod('pause', {'id': id});
  Future<void> seek(int ms) => _ch.invokeMethod('seek', {'id': id, 'ms': ms});
  Future<int> position() async =>
      ((await _ch.invokeMethod<num>('position', {'id': id})) ?? 0).toInt();
  Future<void> dispose() async {
    if (id < 0) return;
    try {
      await _ch.invokeMethod('dispose', {'id': id});
    } catch (_) {}
  }

  /// Poster fast path: one frame via MediaMetadataRetriever (Android). Null
  /// when the platform/file can't provide one — caller uses the wasm scan.
  static Future<Uint8List?> thumbnail(
    String path, {
    int atMs = 1000,
    int maxPx = 480,
  }) async {
    try {
      return await _ch.invokeMethod<Uint8List>('thumbnail', {
        'path': path,
        'atMs': atMs,
        'maxPx': maxPx,
      });
    } catch (_) {
      return null;
    }
  }
}

class HwVideoPlayer extends StatefulWidget {
  final Uint8List mediaBytes;
  final String ext;
  final BoxFit fit;
  final bool allowFullscreen;

  /// The hardware path failed (create error, prepare timeout, no video track,
  /// MediaPlayer error) — the dispatcher swaps in the wasm player.
  final void Function(String reason) onFailed;

  const HwVideoPlayer({
    super.key,
    required this.mediaBytes,
    required this.ext,
    required this.onFailed,
    this.fit = BoxFit.contain,
    this.allowFullscreen = true,
  });

  @override
  State<HwVideoPlayer> createState() => _HwVideoPlayerState();
}

class _HwVideoPlayerState extends State<HwVideoPlayer> {
  final _c = HwVideoController();
  StreamSubscription? _sub;
  Timer? _prepareTimeout;
  Directory? _tempDir;
  bool _prepared = false;
  bool _ended = false;
  bool _failed = false;
  int _videoW = 0, _videoH = 0;
  final _t0 = Stopwatch()..start();

  // Time bar: duration from the 'prepared' event, position polled while
  // playing (MediaPlayer has no position push).
  int _durMs = 0;
  final _posMs = ValueNotifier<int>(0);
  Timer? _posPoll;

  void _startPosPoll() {
    _posPoll ??= Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!mounted || !_prepared || _failed) return;
      try {
        _posMs.value = _ended && _durMs > 0 ? _durMs : await _c.position();
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _log('hw start .${widget.ext} ${widget.mediaBytes.length} B');
      final dir = await Directory.systemTemp.createTemp('aurora_hwvid_');
      _tempDir = dir;
      final f = File('${dir.path}/v.${widget.ext}');
      await f.writeAsBytes(widget.mediaBytes, flush: true);
      if (!mounted) {
        _cleanup();
        return;
      }
      // Subscribe BEFORE create so a fast 'prepared' can't be missed.
      _sub = HwVideoController.events().listen(_onEvent);
      await _c.create(f.path);
      if (!mounted) {
        _cleanup();
        return;
      }
      // Local file → MediaCodec init is near-instant; 5 s means broken.
      _prepareTimeout = Timer(const Duration(seconds: 5), () {
        if (!_prepared) _fail('prepare timeout');
      });
      setState(() {}); // textureId known
    } catch (e) {
      _fail('create: $e');
    }
  }

  void _onEvent(Map<dynamic, dynamic> m) {
    if (m['id'] != _c.id) return;
    switch (m['event']) {
      case 'prepared':
        _prepareTimeout?.cancel();
        final w = (m['width'] as num?)?.toInt() ?? 0;
        final h = (m['height'] as num?)?.toInt() ?? 0;
        if (w <= 0 || h <= 0) {
          // Audio-only file posted as video — wasm renders those better.
          _fail('no video track');
          return;
        }
        _log('hw prepared ${w}x$h in ${_t0.elapsedMilliseconds} ms');
        if (mounted) {
          setState(() {
            _prepared = true;
            _videoW = w;
            _videoH = h;
            _durMs = (m['durationMs'] as num?)?.toInt() ?? 0;
          });
          _startPosPoll();
        }
      case 'completed':
        if (mounted) setState(() => _ended = true);
      case 'error':
        _fail('MediaPlayer error what=${m['what']} extra=${m['extra']}');
    }
  }

  void _fail(String reason) {
    if (_failed) return;
    _failed = true;
    _log('hw failed: $reason');
    _cleanup();
    if (mounted) widget.onFailed(reason);
  }

  Future<void> _replay() async {
    try {
      await _c.seek(0);
      await _c.play();
      _hwPlaying = true;
      if (mounted) setState(() => _ended = false);
    } catch (_) {}
  }

  bool _hwPlaying = true;

  Future<void> _seekTo(int ms) async {
    try {
      await _c.seek(ms);
      _posMs.value = ms;
      if (_ended) {
        await _c.play();
        _hwPlaying = true;
        if (mounted) setState(() => _ended = false);
      }
    } catch (_) {}
  }

  Future<void> _togglePlay() async {
    try {
      if (_hwPlaying) {
        await _c.pause();
      } else {
        await _c.play();
      }
      _hwPlaying = !_hwPlaying;
    } catch (_) {}
  }

  void _openFullscreen() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => _FullscreenHwVideo(
          textureId: _c.textureId,
          width: _videoW,
          height: _videoH,
          onTogglePlay: () => unawaited(_togglePlay()),
        ),
      ),
    );
  }

  void _cleanup() {
    _prepareTimeout?.cancel();
    _posPoll?.cancel();
    _posPoll = null;
    _sub?.cancel();
    unawaited(_c.dispose());
    try {
      _tempDir?.deleteSync(recursive: true);
    } catch (_) {}
    _tempDir = null;
  }

  @override
  void dispose() {
    _cleanup();
    _posMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_prepared && _c.textureId >= 0)
            FittedBox(
              fit: widget.fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _videoW.toDouble(),
                height: _videoH.toDouble(),
                child: Texture(textureId: _c.textureId),
              ),
            ),
          if (!_prepared)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Starting…',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          if (_ended)
            Center(
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _replay,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.replay, color: Colors.white, size: 34),
                  ),
                ),
              ),
            ),
          if (_prepared)
            Positioned(
              left: 6,
              right: widget.allowFullscreen ? 42 : 6,
              bottom: 6,
              child: VideoTimeBar(
                positionMs: _posMs,
                durationMs: _durMs,
                onSeek: (ms) => unawaited(_seekTo(ms)),
              ),
            ),
          if (widget.allowFullscreen && _prepared)
            Positioned(
              right: 4,
              bottom: 4,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _openFullscreen,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.fullscreen,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Fullscreen view of the SAME texture — the decoder keeps running behind
/// the route (a Texture widget can composite in two places), so there is a
/// single decoder and no restart, matching the wasm session's behavior.
class _FullscreenHwVideo extends StatelessWidget {
  final int textureId;
  final int width;
  final int height;
  final VoidCallback? onTogglePlay;
  const _FullscreenHwVideo({
    required this.textureId,
    required this.width,
    required this.height,
    this.onTogglePlay,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: VideoKeyScope(
        onTogglePlay: onTogglePlay,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: width.toDouble(),
                  height: height.toDouble(),
                  child: Texture(textureId: textureId),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.of(context).pop(),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.close, color: Colors.white, size: 24),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
