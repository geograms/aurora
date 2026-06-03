/*
 * Media capability — the host-side seam for the `media.video`
 * capability that the `mediapack` library wapp advertises.
 *
 * Why this exists: a WASM wapp cannot draw a native video surface, and
 * Flutter links its packages at compile time, so the actual player
 * (media_kit) has to live in the host binary. To keep that from being
 * hardwired into the wapp runtime, the player is modelled as a
 * *capability*:
 *
 *   - The platform-specific backend (media_kit) registers itself here
 *     at startup via [MediaCapabilities.registerBackend] — and only on
 *     platforms it supports. The wapp runtime never imports media_kit.
 *   - The capability is only *active* when a library wapp advertising
 *     `media.video` is actually installed (checked against the
 *     [FunctionalityRegistry]). Remove the mediapack wapp and video
 *     goes away; ship a different backend and it swaps cleanly.
 *
 * This file has NO dependency on media_kit, so the wapp runtime can talk
 * to video through [MediaSession] without pulling the engine into core.
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
