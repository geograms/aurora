import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

/// Position + orientation of one card in world space (y-up, right-handed,
/// camera looks down -z — the convention three.js uses).
@immutable
class Pose {
  const Pose(this.position, this.rotation);

  final Vector3 position;
  final Quaternion rotation;

  Matrix4 get matrix => Matrix4.compose(position, rotation, Vector3.all(1));

  /// The card's outward normal in world space: the direction a viewer must
  /// approach from to read it.
  ///
  /// Deliberately not `rotation.rotated`: in vector_math that applies the
  /// *inverse* rotation, while `asRotationMatrix`, `Matrix4.compose` and
  /// `Quaternion.fromRotation` all apply the forward one.
  Vector3 get facing => rotation.asRotationMatrix() * Vector3(0, 0, 1);
}

Pose lerpPose(Pose a, Pose b, double t) => Pose(
  a.position + (b.position - a.position) * t,
  slerp(a.rotation, b.rotation, t),
);

/// Shortest-arc quaternion interpolation. vector_math ships no slerp.
Quaternion slerp(Quaternion a, Quaternion b, double t) {
  var cosHalfTheta = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  var bx = b.x, by = b.y, bz = b.z, bw = b.w;
  if (cosHalfTheta < 0) {
    cosHalfTheta = -cosHalfTheta;
    bx = -bx;
    by = -by;
    bz = -bz;
    bw = -bw;
  }
  if (cosHalfTheta > 0.9995) {
    return Quaternion(
      a.x + (bx - a.x) * t,
      a.y + (by - a.y) * t,
      a.z + (bz - a.z) * t,
      a.w + (bw - a.w) * t,
    )..normalize();
  }
  final halfTheta = math.acos(cosHalfTheta);
  final sinHalfTheta = math.sqrt(1 - cosHalfTheta * cosHalfTheta);
  final ratioA = math.sin((1 - t) * halfTheta) / sinHalfTheta;
  final ratioB = math.sin(t * halfTheta) / sinHalfTheta;
  return Quaternion(
    a.x * ratioA + bx * ratioB,
    a.y * ratioA + by * ratioB,
    a.z * ratioA + bz * ratioB,
    a.w * ratioA + bw * ratioB,
  )..normalize();
}

/// Orientation whose +z axis points from [position] towards [target].
/// Mirrors three.js `Object3D.lookAt` for non-camera objects.
Quaternion lookAtQuaternion(Vector3 position, Vector3 target) {
  final up = Vector3(0, 1, 0);
  var z = target - position;
  if (z.length2 == 0) z.z = 1;
  z.normalize();

  var x = up.cross(z);
  if (x.length2 == 0) {
    // up and z are parallel — nudge z so the basis stays well defined.
    if (z.z.abs() == 1) {
      z.x += 0.0001;
    } else {
      z.z += 0.0001;
    }
    z.normalize();
    x = up.cross(z);
  }
  x.normalize();
  final y = z.cross(x);

  return Quaternion.fromRotation(
    Matrix3(x.x, x.y, x.z, y.x, y.y, y.z, z.x, z.y, z.z),
  );
}

/// TWEEN.Easing.Exponential.InOut, which the original uses. Far snappier
/// through the middle than a cubic ease.
double exponentialInOut(double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  final k = t * 2;
  if (k < 1) return 0.5 * math.pow(1024, k - 1);
  return 0.5 * (2 - math.pow(2, -10 * (k - 1)));
}
