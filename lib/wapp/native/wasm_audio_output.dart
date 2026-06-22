/*
 * WasmAudioOutput — the host-side speaker sink for PCM a wapp decodes in wasm.
 *
 * The Player wapp decodes audio (mp3/aac/vorbis/…) in WebAssembly and pushes
 * raw PCM through the hal_audio_pcm import; the host must put it out the
 * speaker. That output is inherently platform-specific (a DAC, not a codec),
 * so it uses a tiny cross-platform raw-PCM plugin (flutter_pcm_sound,
 * Android/iOS/macOS). It is NOT a codec — the codecs stay in the wapp.
 *
 * flutter_pcm_sound is PULL-based: you register a feed callback that fires when
 * its internal buffer runs low, and you feed() more 16-bit PCM. The wapp is
 * PUSH-based. This class bridges the two: pushPcm() enqueues (converting f32→
 * s16 and capping the queue), and the feed callback drains the queue (feeding a
 * little silence if momentarily empty so the callback keeps firing). It also
 * exposes [playedPosition] — the audio's actual playback time — which the video
 * session uses as the A/V master clock.
 *
 * Everything is guarded: on a platform without the plugin (Linux/Windows) or
 * any error it degrades to dropping audio (today's behaviour), never crashing.
 */

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class WasmAudioOutput {
  int _rate = 0;
  int _channels = 1;
  bool _setupStarted = false; // async setup kicked off
  bool _ready = false; // setup completed, feeding live
  bool _disposed = false;
  bool _failed = false; // plugin unavailable → drop audio

  // Pending s16 PCM, as a list of byte chunks (cheap append/pop-front).
  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;
  static const int _maxQueueBytes = 8 * 1024 * 1024; // ~bounds memory

  int _fedFrames = 0; // total frames handed to the plugin
  int _remaining = 0; // last reported still-buffered frames
  final Stopwatch _sinceReport = Stopwatch(); // interpolate between callbacks
  bool _paused = false;

  /// The audio's actual playback position — the A/V master clock. Derived from
  /// frames the plugin has consumed (fed − remaining), interpolated between
  /// low-buffer callbacks. Zero until audio actually starts.
  Duration get playedPosition {
    if (_rate <= 0) return Duration.zero;
    final consumed = (_fedFrames - _remaining).clamp(0, _fedFrames);
    var ms = (consumed * 1000) ~/ _rate;
    if (!_paused && _sinceReport.isRunning) {
      ms += _sinceReport.elapsedMilliseconds;
    }
    // Never claim to be ahead of what we've fed.
    final fedMs = (_fedFrames * 1000) ~/ _rate;
    return Duration(milliseconds: ms > fedMs ? fedMs : ms);
  }

  bool get active => _ready && !_failed && !_disposed;

  /// Called from the wapp's hal_audio_pcm. [sampfmt] 0 = s16 interleaved,
  /// 1 = f32 interleaved. [ptsMs] is currently unused (push order is in order).
  void pushPcm(
      Uint8List pcm, int rate, int channels, int sampfmt, int ptsMs) {
    if (_disposed || _failed || rate <= 0 || channels <= 0) return;
    final s16 = sampfmt == 1 ? _f32ToS16(pcm) : pcm;
    if (s16.isEmpty) return;
    if (!_setupStarted) {
      _rate = rate;
      _channels = channels;
      _setupStarted = true;
      _init();
    }
    // Format changes mid-stream aren't expected; ignore (would need re-setup).
    if (_pendingBytes >= _maxQueueBytes) return; // overrun guard
    _pending.add(s16);
    _pendingBytes += s16.length;
  }

  void pause() {
    _paused = true;
    _sinceReport.stop();
  }

  void resume() {
    _paused = false;
    if (_ready) _sinceReport.start();
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    _pendingBytes = 0;
    if (_setupStarted && !_failed) {
      try {
        FlutterPcmSound.setFeedCallback(null);
        FlutterPcmSound.release();
      } catch (_) {}
    }
  }

  Future<void> _init() async {
    try {
      await FlutterPcmSound.setup(
          sampleRate: _rate, channelCount: _channels);
      // Fire the feed callback when fewer than ~150ms remain buffered.
      await FlutterPcmSound.setFeedThreshold(_rate ~/ 7);
      FlutterPcmSound.setFeedCallback(_onFeed);
      if (_disposed) {
        try {
          FlutterPcmSound.release();
        } catch (_) {}
        return;
      }
      _ready = true;
      _sinceReport.start();
      FlutterPcmSound.start(); // kicks the first feed callback
    } catch (_) {
      _failed = true; // no plugin on this platform → silently drop audio
    }
  }

  void _onFeed(int remainingFrames) {
    if (_disposed || _failed) return;
    _remaining = remainingFrames;
    _sinceReport
      ..reset()
      ..start();
    // Feed up to ~250ms of real PCM; if momentarily empty, feed a little
    // silence so the plugin keeps invoking us (otherwise playback stalls).
    final wantBytes = (_rate * _channels * 2) ~/ 4; // 250ms of s16
    var out = _takePending(wantBytes);
    out ??= Uint8List((_rate ~/ 50) * _channels * 2); // 20ms silence
    final frames = out.length ~/ (2 * _channels);
    _fedFrames += frames;
    try {
      FlutterPcmSound.feed(PcmArrayInt16(
          bytes: ByteData.view(out.buffer, out.offsetInBytes, out.length)));
    } catch (_) {
      _failed = true;
    }
  }

  /// Pop up to [maxBytes] of queued PCM as one contiguous buffer, or null if
  /// the queue is empty.
  Uint8List? _takePending(int maxBytes) {
    if (_pending.isEmpty) return null;
    final out = BytesBuilder(copy: false);
    var taken = 0;
    while (_pending.isNotEmpty && taken < maxBytes) {
      final head = _pending.first;
      final room = maxBytes - taken;
      if (head.length <= room) {
        out.add(head);
        taken += head.length;
        _pending.removeAt(0);
        _pendingBytes -= head.length;
      } else {
        out.add(Uint8List.sublistView(head, 0, room));
        _pending[0] = Uint8List.sublistView(head, room);
        _pendingBytes -= room;
        taken += room;
      }
    }
    // s16 frames must be whole — trim to a multiple of (2*channels).
    var bytes = out.toBytes();
    final frameBytes = 2 * _channels;
    final rem = bytes.length % frameBytes;
    if (rem != 0 && bytes.length > rem) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - rem);
    }
    return bytes.isEmpty ? null : bytes;
  }

  static Uint8List _f32ToS16(Uint8List f32bytes) {
    final n = f32bytes.length ~/ 4;
    final f = Float32List.view(f32bytes.buffer, f32bytes.offsetInBytes, n);
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      var v = f[i];
      if (v > 1.0) v = 1.0;
      if (v < -1.0) v = -1.0;
      out[i] = (v * 32767.0).round();
    }
    return out.buffer.asUint8List();
  }
}
