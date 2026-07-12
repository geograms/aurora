/*
 * NativeProcessVideoPlayer — inline video decoded by a NATIVE binary that
 * ships INSIDE the player wapp (manifest `provides.native_binaries`, e.g. a
 * static ffmpeg for linux-x86_64 / windows-x86_64).
 *
 * The host stays codec-free: the binary travels with the signed wapp and is
 * spawned per playback — the same trust boundary as `hal_process_exec`.
 * Decoded RGBA frames stream over stdout into the SAME sink the wasm player
 * uses ([WasmVideoSession]), so pacing, fullscreen and rendering behavior
 * are identical; only the decode engine differs (native SIMD + threads →
 * full-rate 1080p+ where wasm's pure-C fallback can't keep up).
 *
 * Any failure (no binary for this platform/arch, spawn error, unparseable
 * probe, no frames) reports [onFailed] and the dispatcher swaps in the wasm
 * player.
 */

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../launcher/launcher.dart' show WappManifest;
import '../../services/log_service.dart';
import 'video_keys.dart';
import 'video_time_bar.dart';
import 'wasm_audio_output.dart';
import 'wasm_video_session.dart';

void _log(String line) {
  LogService.instance.add('[wvp] $line');
  debugPrint('[wvp] $line');
}

/// `<platform>-<arch>` key for the running host, matching the manifest's
/// `provides.native_binaries` keys. Null on platforms we don't map.
String? nativeBinaryKey() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.linuxX64 => 'linux-x86_64',
    Abi.linuxArm64 => 'linux-arm64',
    Abi.windowsX64 => 'windows-x86_64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.macosX64 => 'macos-x86_64',
    Abi.macosArm64 => 'macos-arm64',
    _ => null,
  };
}

/// Absolute path of [manifest]'s native decoder binary for this host, or
/// null when the wapp doesn't ship one for this platform/arch (or the file
/// is missing on disk).
String? nativeDecoderPathFor(WappManifest manifest) {
  final key = nativeBinaryKey();
  if (key == null) return null;
  final rel = manifest.nativeBinaries[key];
  if (rel == null) return null;
  final path =
      '${manifest.dirPath}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
  return File(path).existsSync() ? path : null;
}

class NativeProcessVideoPlayer extends StatefulWidget {
  final String binaryPath;
  final Uint8List mediaBytes;
  final String ext;
  final BoxFit fit;
  final bool allowFullscreen;
  final void Function(String reason) onFailed;

  const NativeProcessVideoPlayer({
    super.key,
    required this.binaryPath,
    required this.mediaBytes,
    required this.ext,
    required this.onFailed,
    this.fit = BoxFit.contain,
    this.allowFullscreen = true,
  });

  @override
  State<NativeProcessVideoPlayer> createState() =>
      _NativeProcessVideoPlayerState();
}

class _NativeProcessVideoPlayerState extends State<NativeProcessVideoPlayer> {
  WasmVideoSession? _session;
  WasmAudioOutput? _audioOut;
  Process? _videoProc;
  Process? _audioProc;
  Directory? _tempDir;
  StreamSubscription<List<int>>? _videoSub;
  StreamSubscription<List<int>>? _audioSub;
  Timer? _firstFrameTimeout;
  bool _failed = false;
  bool _gotFrame = false;
  String? _mediaPath;

  // Probe results.
  int _w = 0, _h = 0;
  double _fps = 30;
  int _durMs = 0;

  // Decode-ahead pacing: the pipe would otherwise buffer the whole clip.
  final _clock = Stopwatch();
  static const _leadMs = 700;
  static const _audioLeadMs = 1500;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final t0 = Stopwatch()..start();
    try {
      _log(
        'native start .${widget.ext} ${widget.mediaBytes.length} B '
        'bin=${widget.binaryPath.split(Platform.pathSeparator).last}',
      );
      final dir = await Directory.systemTemp.createTemp('aurora_natvid_');
      _tempDir = dir;
      final f = File('${dir.path}/v.${widget.ext}');
      await f.writeAsBytes(widget.mediaBytes, flush: true);
      _mediaPath = f.path;

      if (Platform.isLinux || Platform.isMacOS) {
        // Wapp unpack does not preserve the execute bit — set it lazily.
        await Process.run('chmod', ['+x', widget.binaryPath]);
      }

      if (!await _probe(f.path)) return; // _fail already called
      if (!mounted) return _cleanup();

      final session = WasmVideoSession();
      session.durationMs = _durMs;
      final audioOut = WasmAudioOutput();
      session.masterClock = () =>
          audioOut.active ? audioOut.playedPosition : null;
      _session = session;
      _audioOut = audioOut;
      session.open(f.path, autoplay: true);

      await _spawnVideo(f.path);
      await _spawnAudio(f.path);
      if (!mounted) return _cleanup();
      setState(() {});
      _log(
        'native opened ${_w}x$_h @${_fps.toStringAsFixed(1)}fps '
        'in ${t0.elapsedMilliseconds} ms',
      );
      _firstFrameTimeout = Timer(const Duration(seconds: 6), () {
        if (!_gotFrame) _fail('no frames from native decoder');
      });
    } catch (e) {
      _fail('native start: $e');
    }
  }

  /// Parse stream geometry from the decoder's own probe output
  /// (`-i file` with no output exits non-zero but prints stream info).
  Future<bool> _probe(String path) async {
    final r = await Process.run(widget.binaryPath, [
      '-hide_banner',
      '-i',
      path,
    ]).timeout(const Duration(seconds: 10));
    final err = (r.stderr ?? '').toString();
    final dim = RegExp(r'Video:.* (\d{2,5})x(\d{2,5})').firstMatch(err);
    if (dim == null) {
      _fail('probe: no video stream');
      return false;
    }
    _w = int.parse(dim.group(1)!);
    _h = int.parse(dim.group(2)!);
    final fps =
        RegExp(r'([\d.]+) fps').firstMatch(err) ??
        RegExp(r'([\d.]+) tbr').firstMatch(err);
    _fps = double.tryParse(fps?.group(1) ?? '') ?? 30;
    if (_fps <= 0 || _fps > 240) _fps = 30;
    final dur = RegExp(
      r'Duration: (\d+):(\d\d):(\d\d(?:\.\d+)?)',
    ).firstMatch(err);
    if (dur != null) {
      _durMs =
          ((int.parse(dur.group(1)!) * 3600 + int.parse(dur.group(2)!) * 60) *
              1000) +
          (double.parse(dur.group(3)!) * 1000).round();
    }
    if (_w <= 0 || _h <= 0 || _w * _h > 4096 * 4096) {
      _fail('probe: bad dimensions ${_w}x$_h');
      return false;
    }
    return true;
  }

  Future<void> _spawnVideo(String path, {int startMs = 0}) async {
    final frameSize = _w * _h * 4;
    final proc = await Process.start(widget.binaryPath, [
      '-v',
      'error',
      if (startMs > 0) ...['-ss', (startMs / 1000).toStringAsFixed(3)],
      '-i',
      path,
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgba',
      'pipe:1',
    ]);
    _videoProc = proc;
    final buf = BytesBuilder(copy: false);
    var frameIdx = 0;
    _videoSub = proc.stdout.listen(
      (chunk) {
        buf.add(chunk);
        while (buf.length >= frameSize) {
          final all = buf.takeBytes();
          final frame = Uint8List.sublistView(all, 0, frameSize); // first frame
          if (all.length > frameSize) {
            buf.add(Uint8List.sublistView(all, frameSize)); // remainder back
          }
          final ptsMs = (frameIdx * 1000 / _fps).round();
          frameIdx++;
          if (!_gotFrame) {
            _gotFrame = true;
            _clock.start();
            _firstFrameTimeout?.cancel();
          }
          _session?.pushFrame(
            Uint8List.fromList(frame),
            _w,
            _h,
            0 /*rgba*/,
            ptsMs,
          );
          // Decode-ahead gate: pause the pipe once we're LEAD ahead of the
          // wall clock so a whole movie never piles into memory.
          if (ptsMs > _clock.elapsedMilliseconds + _leadMs) {
            _videoSub?.pause();
            Timer(
              Duration(
                milliseconds:
                    (ptsMs - _clock.elapsedMilliseconds - _leadMs ~/ 2).clamp(
                      20,
                      1000,
                    ),
              ),
              () => _videoSub?.resume(),
            );
            break;
          }
        }
      },
      onDone: () {
        _session?.markEnded();
      },
      onError: (_) {},
    );
    // Surface decoder errors in the log (bounded).
    proc.stderr.transform(const SystemEncoding().decoder).listen((s) {
      final t = s.trim();
      if (t.isNotEmpty)
        _log('native ffmpeg: ${t.substring(0, t.length.clamp(0, 200))}');
    });
  }

  Future<void> _spawnAudio(String path, {int startMs = 0}) async {
    try {
      final proc = await Process.start(widget.binaryPath, [
        '-v',
        'error',
        if (startMs > 0) ...['-ss', (startMs / 1000).toStringAsFixed(3)],
        '-i',
        path,
        '-vn',
        '-f',
        's16le',
        '-ar',
        '44100',
        '-ac',
        '2',
        'pipe:1',
      ]);
      _audioProc = proc;
      var samples = 0;
      _audioSub = proc.stdout.listen((chunk) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        final ptsMs = (samples * 1000 / 44100).round();
        samples += bytes.length ~/ 4; // 2ch × s16
        _audioOut?.pushPcm(bytes, 44100, 2, 0 /*s16*/, ptsMs);
        if (ptsMs > _clock.elapsedMilliseconds + _audioLeadMs) {
          _audioSub?.pause();
          Timer(const Duration(milliseconds: 500), () => _audioSub?.resume());
        }
      }, onError: (_) {});
    } catch (_) {
      // Audio is best-effort — video-only playback is fine (matches the
      // wasm path's behavior on platforms without a PCM sink).
    }
  }

  void _fail(String reason) {
    if (_failed) return;
    _failed = true;
    _log('native failed: $reason');
    _cleanup();
    if (mounted) widget.onFailed(reason);
  }

  bool _userPaused = false;
  bool _seeking = false;

  /// Tap on the time bar: ffmpeg has no live seek over a pipe, so restart
  /// both decode processes at the target (`-ss` before `-i` = fast keyframe
  /// seek). Pipe pts restart at 0; the session's ptsOffset keeps the
  /// displayed position absolute.
  Future<void> _seekTo(int ms) async {
    final path = _mediaPath;
    final s = _session;
    if (_failed || _seeking || path == null || s == null) return;
    _seeking = true;
    try {
      _videoSub?.cancel();
      _audioSub?.cancel();
      try {
        _videoProc?.kill();
      } catch (_) {}
      try {
        _audioProc?.kill();
      } catch (_) {}
      _clock
        ..stop()
        ..reset();
      _gotFrame = false;
      _userPaused = false;
      s.seek(Duration(milliseconds: ms)); // clears queue, restarts clock
      s.ptsOffsetMs = ms;
      s.positionMs.value = ms;
      // Fresh audio sink — its consumed-frames clock (the A/V master) must
      // restart from zero with the new stream.
      _audioOut?.dispose();
      final audioOut = WasmAudioOutput();
      _audioOut = audioOut;
      s.masterClock = () => audioOut.active ? audioOut.playedPosition : null;
      await _spawnVideo(path, startMs: ms);
      await _spawnAudio(path, startMs: ms);
      _firstFrameTimeout?.cancel();
      _firstFrameTimeout = Timer(const Duration(seconds: 6), () {
        if (!_gotFrame) _fail('no frames after seek');
      });
    } catch (e) {
      _fail('seek: $e');
    } finally {
      _seeking = false;
    }
  }

  /// SPACE in fullscreen. Pausing adds a hold on both pipe subscriptions
  /// (StreamSubscription.pause is counted, so the decode-ahead throttle's
  /// own pause/resume pairs stay balanced around it) and freezes the
  /// pacing clocks; resuming releases them.
  void _togglePause() {
    _userPaused = !_userPaused;
    if (_userPaused) {
      _videoSub?.pause();
      _audioSub?.pause();
      _session?.pause();
      _audioOut?.pause();
      _clock.stop();
    } else {
      _clock.start();
      _session?.play();
      _audioOut?.resume();
      _videoSub?.resume();
      _audioSub?.resume();
    }
  }

  void _openFullscreen() {
    final s = _session;
    if (s == null) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => Scaffold(
          backgroundColor: Colors.black,
          body: VideoKeyScope(
            onTogglePlay: _togglePause,
            child: Stack(
              fit: StackFit.expand,
              children: [
                s.buildSurface(BoxFit.contain),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: SafeArea(
                    child: VideoTimeBar(
                      positionMs: s.positionMs,
                      durationMs: _durMs,
                      onSeek: (ms) => unawaited(_seekTo(ms)),
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
                          child: Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _cleanup() {
    _firstFrameTimeout?.cancel();
    _videoSub?.cancel();
    _audioSub?.cancel();
    try {
      _videoProc?.kill();
    } catch (_) {}
    try {
      _audioProc?.kill();
    } catch (_) {}
    _session?.dispose();
    _session = null;
    _audioOut?.dispose();
    _audioOut = null;
    try {
      _tempDir?.deleteSync(recursive: true);
    } catch (_) {}
    _tempDir = null;
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (s != null) s.buildSurface(widget.fit),
          if (!_gotFrame)
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
          if (s != null && _gotFrame)
            Positioned(
              left: 6,
              right: widget.allowFullscreen ? 42 : 6,
              bottom: 6,
              child: VideoTimeBar(
                positionMs: s.positionMs,
                durationMs: _durMs,
                onSeek: (ms) => unawaited(_seekTo(ms)),
              ),
            ),
          if (widget.allowFullscreen && s != null && _gotFrame)
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
