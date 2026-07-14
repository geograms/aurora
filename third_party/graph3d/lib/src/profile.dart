import 'package:flutter/foundation.dart';

/// `--dart-define=GRAPH3D_FRAME_STATS=true` turns on per-subsystem timing
/// prints (CROWDPAINT / LINKPAINT / ADVANCE), so a slow frame can be
/// attributed rather than guessed at. Consumers pair it with a frame-timings
/// reporter; see the mesh_demo example.
const bool kProfileScene = bool.fromEnvironment('GRAPH3D_FRAME_STATS');

/// Prints a rolling per-frame average for one named subsystem.
class ProfileTimer {
  ProfileTimer(this.name);

  final String name;
  final Stopwatch _watch = Stopwatch();
  int _calls = 0;

  void time(void Function() body) {
    if (!kProfileScene) {
      body();
      return;
    }
    _watch.start();
    body();
    _watch.stop();
    if (++_calls % 60 == 0) {
      debugPrint(
        '$name avg=${(_watch.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)}ms/frame',
      );
      _watch.reset();
    }
  }
}
