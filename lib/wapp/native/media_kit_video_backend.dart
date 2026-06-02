/*
 * media_kit implementation of the [MediaVideoBackend] capability. This
 * is the ONLY file in the app that imports media_kit — it's the
 * platform backend behind the `mediapack` library wapp. Swapping media
 * engines, or dropping video on a platform, is a change confined here +
 * the registration call in main.dart.
 */

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_capability.dart';

/// Initialise media_kit and register it as the media.video backend, but
/// only on a platform it supports. Called once from main.dart with the
/// host's [platformName]. Keeps the media_kit import out of main/core —
/// this file is the sole place it appears.
void registerMediaKitBackend(String platformName) {
  const supported = ['linux', 'macos', 'windows', 'android', 'ios'];
  if (!supported.contains(platformName)) return;
  try {
    MediaKit.ensureInitialized();
    MediaCapabilities.registerBackend(MediaKitVideoBackend());
  } catch (_) {
    // Native libs missing — leave the capability unbacked; the movies
    // wapp will report video unsupported instead of crashing boot.
  }
}

class MediaKitVideoBackend implements MediaVideoBackend {
  @override
  List<String> get supportedPlatforms =>
      const ['linux', 'macos', 'windows', 'android', 'ios'];

  @override
  MediaSession createSession() => _MediaKitSession();
}

class _MediaKitSession implements MediaSession {
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  Widget buildSurface(BoxFit fit) => Video(controller: _controller, fit: fit);

  @override
  void open(String path, {bool autoplay = true}) {
    try {
      _player.open(Media(path), play: autoplay);
    } catch (_) {}
  }

  @override
  void play() {
    try {
      _player.play();
    } catch (_) {}
  }

  @override
  void pause() {
    try {
      _player.pause();
    } catch (_) {}
  }

  @override
  void stop() {
    try {
      _player.stop();
    } catch (_) {}
  }

  @override
  void seek(Duration position) {
    try {
      _player.seek(position);
    } catch (_) {}
  }

  @override
  void skip(Duration delta) {
    try {
      _player.seek(_player.state.position + delta);
    } catch (_) {}
  }

  @override
  void setSubtitle(String path) {
    try {
      _player.setSubtitleTrack(SubtitleTrack.uri(Uri.file(path).toString()));
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _player.dispose();
    } catch (_) {}
  }
}
