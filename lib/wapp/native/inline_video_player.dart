/*
 * inlineVideoPlayer — chooses the playback backend for inline media:
 *
 *   1. Android video → hardware MediaPlayer (HwVideoPlayer): the OS's own
 *      decoder silicon, zero bundled codecs, full-rate 1080p+/HEVC.
 *   2. Desktop video where the player wapp ships a native decoder binary
 *      for this platform/arch → NativeProcessVideoPlayer (real SIMD +
 *      threads; the binary travels inside the signed wapp).
 *   3. Audio, every other platform, and ANY failure of 1/2 → the wasm
 *      decoder (WasmVideoPlayer) — the slow-but-universal fallback.
 *
 * Every fallback is logged as `[wvp] … fallback:` so field reports are
 * diagnosable from /api/log.
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/log_service.dart';
import 'hw_video_player.dart';
import 'native_process_video_player.dart';
import 'wasm_video_player.dart';

Widget inlineVideoPlayer({
  required Uint8List mediaBytes,
  required String ext,
  BoxFit fit = BoxFit.contain,
  bool allowFullscreen = true,
  bool isAudio = false,
  String? title,
}) {
  Widget wasm() => WasmVideoPlayer(
        mediaBytes: mediaBytes,
        ext: ext,
        fit: fit,
        allowFullscreen: allowFullscreen,
        isAudio: isAudio,
        title: title,
      );

  if (isAudio) return wasm();

  if (Platform.isAndroid) {
    return _FastWithWasmFallback(
      buildFast: (onFailed) => HwVideoPlayer(
        mediaBytes: mediaBytes,
        ext: ext,
        fit: fit,
        allowFullscreen: allowFullscreen,
        onFailed: onFailed,
      ),
      buildWasm: wasm,
      label: 'hw',
    );
  }

  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final matches = framePushPlayersFor(ext);
    if (matches.isNotEmpty) {
      final bin = nativeDecoderPathFor(matches.first.manifest);
      if (bin != null) {
        return _FastWithWasmFallback(
          buildFast: (onFailed) => NativeProcessVideoPlayer(
            binaryPath: bin,
            mediaBytes: mediaBytes,
            ext: ext,
            fit: fit,
            allowFullscreen: allowFullscreen,
            onFailed: onFailed,
          ),
          buildWasm: wasm,
          label: 'native',
        );
      }
    }
  }

  return wasm();
}

/// Runs the fast backend; swaps to the wasm player the moment it reports
/// failure (create error, prepare/first-frame timeout, decoder error —
/// including mid-playback, where wasm restarts from 0).
class _FastWithWasmFallback extends StatefulWidget {
  final Widget Function(void Function(String reason) onFailed) buildFast;
  final Widget Function() buildWasm;
  final String label;
  const _FastWithWasmFallback({
    required this.buildFast,
    required this.buildWasm,
    required this.label,
  });

  @override
  State<_FastWithWasmFallback> createState() => _FastWithWasmFallbackState();
}

class _FastWithWasmFallbackState extends State<_FastWithWasmFallback> {
  bool _useWasm = false;

  @override
  Widget build(BuildContext context) {
    if (_useWasm) return widget.buildWasm();
    return widget.buildFast((reason) {
      LogService.instance.add('[wvp] ${widget.label} fallback: $reason');
      if (mounted) setState(() => _useWasm = true);
    });
  }
}
