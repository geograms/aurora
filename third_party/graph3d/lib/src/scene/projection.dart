import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:vector_math/vector_math_64.dart';

import 'orbit_camera.dart' show kFovRadians;

/// Card footprint in world units, matching the CSS `.element` box.
const double kCardWidth = 120;
const double kCardHeight = 160;

/// The distance at which a card renders at its natural size — the number
/// `CSS3DRenderer` writes into the CSS `perspective` property.
double perspectiveFor(double viewportHeight) =>
    0.5 / math.tan(kFovRadians / 2) * viewportHeight;

/// Projects world points onto the screen exactly the way the card [Transform]
/// matrices do, so lines drawn behind the cards land on their corners.
///
/// Screen coordinates are relative to the viewport centre, y down.
class Projector {
  Projector({required this.view, required this.perspective})
    : _clip = Matrix4.diagonal3Values(1, -1, 1) *
          (Matrix4.identity()..setEntry(3, 2, -1 / perspective)) *
          Matrix4.translationValues(0, 0, perspective);

  final Matrix4 view;
  final double perspective;
  final Matrix4 _clip;

  /// The full model-to-screen matrix for a card at [model].
  ///
  /// The world is y-up and the screen is y-down. Flipping on both sides of the
  /// model transform keeps the card's contents upright.
  Matrix4 cardMatrix(Matrix4 model) =>
      _clip * (view * model) * Matrix4.diagonal3Values(1, -1, 1);

  /// Depth of a world point in camera space. Negative is in front of the eye,
  /// and more negative is farther away.
  double depthOf(Vector3 world) => view.transformed3(world).z;

  /// Null when the point sits behind, or level with, the eye — where the
  /// perspective divide would flip it back into view.
  ProjectedPoint? project(Vector3 world) {
    final camera = view.transformed3(world);
    if (camera.z > -1) return null;
    final screen = _clip.perspectiveTransform(camera.clone());
    return ProjectedPoint(
      Offset(screen.x, screen.y),
      camera.z,
      perspective / -camera.z,
    );
  }
}

class ProjectedPoint {
  const ProjectedPoint(this.screen, this.depth, this.scale);

  /// Offset from the viewport centre, y down.
  final Offset screen;

  /// Camera-space z. More negative is farther from the eye.
  final double depth;

  /// Screen pixels per world unit at this point's depth.
  final double scale;
}
