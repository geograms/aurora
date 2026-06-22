/*
 * Media capability — the host-side seam for the `media.video`
 * capability that the `mediapack` library wapp advertises.
 *
 * Why this exists: the actual codec/player must NOT live in the host
 * binary (it bloats the app and is not platform agnostic). Instead the
 * decoder runs as WebAssembly INSIDE a downloadable media wapp, and the
 * host provides only a generic, codec-free render sink. The player is
 * modelled as a *capability*:
 *
 *   - The host registers a codec-free backend at startup via
 *     [MediaCapabilities.registerBackend] — see WasmVideoBackend in
 *     wasm_video_session.dart, which only uploads RGBA frames the wapp
 *     pushes (no codec, no media_kit, no platform plugin).
 *   - The capability is only *active* when a wapp advertising
 *     `media.video` is actually installed (checked against the
 *     [FunctionalityRegistry]). Remove that wapp and video goes away.
 *
 * This file has NO codec dependency; the wapp runtime talks to video
 * through [MediaSession], and the decoder travels inside the .wapp.
 */

import 'package:flutter/widgets.dart';

import '../functionality_registry.dart';

/// The capability id a media-backend library wapp must advertise under
/// `provides.functionalities` for video to light up.
const String kMediaVideoCapability = 'media.video';

/// A single playing surface + its transport controls. One per open
/// movies wapp page. Implemented by the platform backend.
abstract class MediaSession {
  /// The Flutter widget that paints the video.
  Widget buildSurface(BoxFit fit);

  /// Open [path]; start playing unless [autoplay] is false.
  void open(String path, {bool autoplay = true});

  void play();
  void pause();
  void stop();

  /// Seek to an absolute position.
  void seek(Duration position);

  /// Jump by a relative delta from the current position.
  void skip(Duration delta);

  /// Attach an external subtitle file.
  void setSubtitle(String path);

  void dispose();
}

/// A platform backend able to create [MediaSession]s.
abstract class MediaVideoBackend {
  /// OS names this backend works on (linux/windows/macos/android/ios).
  List<String> get supportedPlatforms;

  MediaSession createSession();
}

/// Host registry + install gate for the media.video capability.
class MediaCapabilities {
  MediaCapabilities._();

  static MediaVideoBackend? _backend;

  /// Called once at startup by the platform wiring (main.dart) with the
  /// media_kit backend, only when the current platform is supported.
  static void registerBackend(MediaVideoBackend backend) {
    _backend = backend;
  }

  /// True when a native backend is compiled in for this platform —
  /// regardless of whether the gating wapp is installed.
  static bool get backendAvailable => _backend != null;

  /// The backend to use right now, or null. Non-null requires BOTH a
  /// registered platform backend AND an installed library wapp
  /// advertising [kMediaVideoCapability] (the mediapack wapp).
  static MediaVideoBackend? get active {
    if (_backend == null) return null;
    final providers =
        FunctionalityRegistry.instance.providersFor(kMediaVideoCapability);
    if (providers.isEmpty) return null;
    return _backend;
  }

  /// Convenience: a new session from the active backend, or null when
  /// the capability isn't available/installed.
  static MediaSession? newSession() => active?.createSession();
}
