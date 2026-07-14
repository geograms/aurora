import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

import '../model.dart';
import 'pose.dart';

/// Computes a pose for every node of a scene, in node order.
///
/// Strategies are plain functions so a consumer can lay nodes out from its own
/// data (`node.data`) — the engine ships a few classics below.
typedef LayoutStrategy<T> = LayoutGeometry Function(List<SceneNode<T>> nodes);

/// Card poses for one layout, plus the framing the camera should use for it.
@immutable
class LayoutGeometry {
  const LayoutGeometry({
    required this.poses,
    required this.center,
    required this.radius,
    required this.halfExtent,
  });

  /// Derives the framing from the poses. The extents are seeded at the origin
  /// — matching the original CSS3D app, whose camera always kept the origin in
  /// frame — and widened by half a card so edge cards are not clipped.
  factory LayoutGeometry.fromPoses(List<Pose> poses) {
    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0;
    var minZ = 0.0, maxZ = 0.0;
    for (final pose in poses) {
      minX = math.min(minX, pose.position.x);
      maxX = math.max(maxX, pose.position.x);
      minY = math.min(minY, pose.position.y);
      maxY = math.max(maxY, pose.position.y);
      minZ = math.min(minZ, pose.position.z);
      maxZ = math.max(maxZ, pose.position.z);
    }
    final center = Vector3((minX + maxX) / 2, (minY + maxY) / 2, 0);

    var radius = 0.0;
    for (final pose in poses) {
      radius = math.max(radius, (pose.position - center).length);
    }

    return LayoutGeometry(
      poses: poses,
      center: center,
      radius: radius,
      halfExtent: Vector3(
        (maxX - minX) / 2 + 70,
        (maxY - minY) / 2 + 80,
        (maxZ - minZ) / 2,
      ),
    );
  }

  final List<Pose> poses;

  /// Where the camera aims when the layout is first shown, or reset.
  final Vector3 center;

  /// Distance from [center] out to the farthest card. Bounds panning.
  final double radius;

  /// Half the layout's width, height and depth. The camera backs off far
  /// enough to fit all three.
  final Vector3 halfExtent;
}

/// A flat wall of cards on the z=0 plane, one cell each; [cell] maps a node to
/// its one-based (column, row).
LayoutStrategy<T> tableLayout<T>({
  required (int, int) Function(SceneNode<T> node) cell,
}) {
  return (nodes) => LayoutGeometry.fromPoses(<Pose>[
    for (final node in nodes)
      Pose(
        Vector3(
          cell(node).$1 * 140.0 - 1330,
          -(cell(node).$2 * 180.0) + 990,
          0,
        ),
        Quaternion.identity(),
      ),
  ]);
}

/// A descending spiral, cards facing outwards from the axis.
LayoutStrategy<T> helixLayout<T>({double radius = 900}) {
  return (nodes) => LayoutGeometry.fromPoses(<Pose>[
    for (var i = 0; i < nodes.length; i++) _helixPose(i, radius),
  ]);
}

Pose _helixPose(int i, double radius) {
  final theta = i * 0.175 + math.pi;
  final y = -(i * 8.0) + 450;
  final position = Vector3(
    radius * math.sin(theta),
    y,
    radius * math.cos(theta),
  );
  // Face outwards from the helix axis, without tilting up or down.
  return Pose(
    position,
    lookAtQuaternion(
      position,
      Vector3(position.x * 2, position.y, position.z * 2),
    ),
  );
}

/// Stacked slabs of size x size cards, a thousand units apart in depth.
LayoutStrategy<T> gridLayout<T>({int size = 9}) {
  return (nodes) => LayoutGeometry.fromPoses(<Pose>[
    for (var i = 0; i < nodes.length; i++)
      Pose(
        Vector3(
          (i % size) * 400.0 - 800,
          -((i ~/ size) % size) * 400.0 + 800,
          (i ~/ (size * size)) * 1000.0 - 2000,
        ),
        Quaternion.identity(),
      ),
  ]);
}

/// [count] poses evenly spaced on a horizontal ring about [center].
///
/// With [faceCenter] the cards look inwards at the ring's middle; otherwise
/// they face outwards, the way the helix does.
List<Pose> ringPoses(
  int count, {
  required double radius,
  Vector3? center,
  bool faceCenter = false,
}) {
  final middle = center ?? Vector3.zero();
  return <Pose>[
    for (var i = 0; i < count; i++)
      _ringPose(i, count, radius, middle, faceCenter),
  ];
}

Pose _ringPose(
  int i,
  int count,
  double radius,
  Vector3 center,
  bool faceCenter,
) {
  final theta = 2 * math.pi * i / count;
  final position = Vector3(
    center.x + radius * math.sin(theta),
    center.y,
    center.z + radius * math.cos(theta),
  );
  final target = faceCenter
      ? Vector3(center.x, position.y, center.z)
      : Vector3(
          position.x + (position.x - center.x),
          position.y,
          position.z + (position.z - center.z),
        );
  return Pose(position, lookAtQuaternion(position, target));
}

/// [count] poses scattered over a spherical patch: azimuths sweep
/// [thetaStart, thetaStart + thetaSweep], elevations sit in a band of
/// [phiSpread] around [phiCenter], all at [radius] from [center].
///
/// The scatter is a golden-ratio low-discrepancy sequence: deterministic,
/// even-looking, no physics. Azimuth 0 points along +z, growing towards +x —
/// the same convention as [ringPoses]. Poses face outward from [center].
List<Pose> sectorShellPoses(
  int count, {
  required double radius,
  required double thetaStart,
  required double thetaSweep,
  double phiCenter = math.pi / 2,
  double phiSpread = math.pi / 3,
  Vector3? center,
}) {
  const golden = 0.6180339887498949;
  final middle = center ?? Vector3.zero();
  final poses = <Pose>[];
  for (var i = 0; i < count; i++) {
    final theta = thetaStart + (i + 0.5) / count * thetaSweep;
    final phi =
        phiCenter + (((i * golden) % 1.0) - 0.5) * phiSpread;
    final position = Vector3(
      middle.x + radius * math.sin(phi) * math.sin(theta),
      middle.y + radius * math.cos(phi),
      middle.z + radius * math.sin(phi) * math.cos(theta),
    );
    final outward = position + (position - middle);
    poses.add(Pose(position, lookAtQuaternion(position, outward)));
  }
  return poses;
}

/// [count] poses on a sunflower (Vogel spiral) disc: evenly dense, no rings or
/// spokes, deterministic. The disc lies in the plane of [plane] — its cards
/// share that pose's orientation — centred on its position.
///
/// [spacing] sets the density; neighbours end up roughly `spacing` apart and
/// the disc's radius grows as `spacing * sqrt(count)`.
List<Pose> sunflowerDiscPoses(
  int count, {
  required Pose plane,
  double spacing = 170,
}) {
  // The golden angle spreads consecutive points as far apart as possible.
  const goldenAngle = 2.399963229728653;
  final basis = plane.rotation.asRotationMatrix();
  final right = basis * Vector3(1, 0, 0);
  final up = basis * Vector3(0, 1, 0);

  final poses = <Pose>[];
  for (var i = 0; i < count; i++) {
    final r = spacing * math.sqrt(i + 0.5);
    final theta = i * goldenAngle;
    poses.add(
      Pose(
        plane.position +
            right * (r * math.cos(theta)) +
            up * (r * math.sin(theta)),
        plane.rotation,
      ),
    );
  }
  return poses;
}
