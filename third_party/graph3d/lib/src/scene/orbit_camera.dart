import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:vector_math/vector_math_64.dart';

import 'pose.dart';

/// Vertical field of view, as in the original's `PerspectiveCamera(40, ...)`.
const double kFovRadians = 40 * math.pi / 180;

/// A turntable camera: azimuth and elevation about a movable target, with the
/// horizon always level. This is three.js `OrbitControls`, not a trackball —
/// the graph has an up direction and the original relies on it.
///
/// Drag inputs accumulate into deltas that are consumed a fraction at a time,
/// which is what `enableDamping` does: motion continues briefly after the
/// finger lifts, then eases to a stop.
class OrbitCamera extends ChangeNotifier {
  OrbitCamera({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// Radians of azimuth per full-viewport drag. OrbitControls ships 0.1,
  /// which reads deliberate on a desktop and sluggish under a thumb — touch
  /// apps want 0.2-0.3.
  double rotateSpeed = 0.1;

  /// Fraction of the pending drag consumed per frame. Higher = snappier,
  /// lower = floatier.
  double dampingFactor = 0.1;
  static const double minDistance = 200;
  static const double maxDistance = 60000;

  /// Below this a residual delta is invisible, so the ticker can shut off.
  static const double _epsilon = 1e-5;

  /// Keeps the poles from flipping the horizon.
  static const double _polarLimit = 1e-6;

  Vector3 _target = Vector3.zero();
  double _distance = 8000;

  /// Cinematic idle drift, radians of azimuth per second. Zero disables. The
  /// caller arms and disarms it (the camera cannot see taps); note that a
  /// nonzero drift keeps the whole scene re-rastering every frame.
  double _idleDriftSpeed = 0;
  double get idleDriftSpeed => _idleDriftSpeed;
  set idleDriftSpeed(double value) {
    if (_idleDriftSpeed == value) return;
    _idleDriftSpeed = value;
    if (value != 0) _wake();
  }

  /// Azimuth about +y, measured from +z towards +x.
  double _theta = 0;

  /// Polar angle from +y. pi/2 is level with the target.
  double _phi = math.pi / 2;

  double _thetaDelta = 0;
  double _phiDelta = 0;
  Vector3 _panDelta = Vector3.zero();

  /// Coasting angular velocity from a fling, radians per second.
  double _thetaVelocity = 0;
  double _phiVelocity = 0;

  /// A fling's velocity halves roughly every [flingHalfLife] seconds — the
  /// Google-Earth coast, not a dead stop at finger-up.
  double flingHalfLife = 0.6;

  /// Where the layout sits, and how far the target may stray from it. Without
  /// the tether the user can push the graph into empty space and lose all sense
  /// of where it went.
  Vector3 _home = Vector3.zero();
  double _tetherRadius = 3000;
  Vector3? _homeHalfExtent;

  /// Viewport width over height. A narrow window has to back further off to fit
  /// a wide layout, so the page keeps this current.
  double _aspect = 1.6;
  set aspect(double value) {
    if (value > 0) _aspect = value;
  }

  /// How far back framing may go. Fitting a very wide layout into a portrait
  /// phone can demand a distance that shrinks every card to an unreadable
  /// speck; past this cap the layout overflows instead, and the pan tether
  /// brings the spilled part back. Consumers tune it per situation — a small
  /// overview ring can afford a farther fit than a dense wall of cards.
  double maxFrameDistance = 8000;

  /// How far back the camera must sit for a box of [halfExtent] to fit the
  /// frame, in both axes, with its nearest face still in front of the lens.
  double fitDistance(Vector3 halfExtent) {
    final tangent = math.tan(kFovRadians / 2);
    final vertical = halfExtent.y / tangent;
    final horizontal = halfExtent.x / (tangent * _aspect);
    final fit = (math.max(vertical, horizontal) + halfExtent.z) * 1.08;

    return math.min(fit, maxFrameDistance).clamp(minDistance, maxDistance);
  }

  _Flight? _flight;

  /// A Ticker reports time since it was started, so this is zero at the moment
  /// [_wake] starts one, not a "no previous tick" sentinel.
  Duration _lastTick = Duration.zero;

  double get distance => _distance;
  Vector3 get target => _target.clone();
  bool get isFlying => _flight != null;

  Vector3 get eye =>
      _target +
      Vector3(
        _distance * math.sin(_phi) * math.sin(_theta),
        _distance * math.cos(_phi),
        _distance * math.sin(_phi) * math.cos(_theta),
      );

  /// World-to-camera transform.
  Matrix4 get viewMatrix {
    final view = Matrix4.zero();
    setViewMatrix(view, eye, _target, Vector3(0, 1, 0));
    return view;
  }

  /// The camera's right and up axes in world space, for panning.
  (Vector3, Vector3) get _screenAxes {
    final back = (eye - _target)..normalize();
    var right = Vector3(0, 1, 0).cross(back);
    if (right.length2 < 1e-12) right = Vector3(1, 0, 0);
    right.normalize();
    return (right, back.cross(right));
  }

  /// Frames [center] straight on, cancelling any orbit. Used on startup and
  /// whenever the layout changes.
  ///
  /// Without [halfExtent] the camera falls back to the original's fixed
  /// distance, which leaves the 426-card table too small to read.
  void frame(
    Vector3 center,
    double sceneRadius, {
    Vector3? halfExtent,
    double? distance,
    int durationMs = 1500,
  }) {
    _home = center.clone();
    _homeHalfExtent = halfExtent?.clone();
    // Room to pan the graph aside, never so much that it leaves the screen.
    _tetherRadius = math.max(sceneRadius, 1000);
    final target = distance ??
        (halfExtent == null ? maxFrameDistance : fitDistance(halfExtent));
    _flyTo(
      target: center,
      distance: target.clamp(minDistance, maxDistance),
      theta: 0,
      phi: math.pi / 2,
      durationMs: durationMs,
    );
  }

  /// Frames a plane face-on: the camera flies out along the plane's normal
  /// until a box of [halfExtent] fits the viewport, and the pan tether moves
  /// with it. This is [frame] for content that does not face +z — an expanded
  /// cluster's disc, say.
  void frameFacing(
    Pose plane, {
    required Vector3 halfExtent,
    double? sceneRadius,
    int durationMs = 1500,
  }) {
    _home = plane.position.clone();
    _homeHalfExtent = halfExtent.clone();
    _tetherRadius = math.max(
      sceneRadius ?? math.max(halfExtent.x, halfExtent.y),
      1000,
    );
    final distance = fitDistance(halfExtent);
    final offset = plane.facing * distance;
    _flyTo(
      target: plane.position,
      distance: distance,
      theta: math.atan2(offset.x, offset.z),
      phi: math.acos((offset.y / distance).clamp(-1.0, 1.0)),
      durationMs: durationMs,
    );
  }

  /// Flies the focus to [target] keeping the current viewing angles — the
  /// right move for billboarded sprites, which have no meaningful "face" to
  /// approach. [distance] defaults to holding the current distance.
  void flyToPoint(
    Vector3 target, {
    double? distance,
    int durationMs = 1600,
  }) {
    _flyTo(
      target: target,
      distance: (distance ?? _distance).clamp(minDistance, maxDistance),
      theta: _theta,
      phi: _phi,
      durationMs: durationMs,
    );
  }

  /// Flies to a viewpoint [standoff] units off the face of a card, so it fills
  /// the view the right way round however the layout has turned it.
  void flyToPose(Pose pose, {double standoff = 990, int durationMs = 3000}) {
    final eye = pose.position + pose.facing * standoff;
    final offset = eye - pose.position;
    final radius = offset.length;
    _flyTo(
      target: pose.position,
      distance: radius.clamp(minDistance, maxDistance),
      theta: math.atan2(offset.x, offset.z),
      phi: math.acos((offset.y / radius).clamp(-1.0, 1.0)),
      durationMs: durationMs,
    );
  }

  void _flyTo({
    required Vector3 target,
    required double distance,
    required double theta,
    required double phi,
    required int durationMs,
  }) {
    _thetaDelta = 0;
    _phiDelta = 0;
    _panDelta.setZero();

    // Take the short way round, rather than unwinding a full turn.
    var endTheta = theta;
    while (endTheta - _theta > math.pi) {
      endTheta -= 2 * math.pi;
    }
    while (endTheta - _theta < -math.pi) {
      endTheta += 2 * math.pi;
    }

    if (durationMs <= 0) {
      _flight = null;
      _target = target.clone();
      _distance = distance;
      _theta = theta;
      _phi = phi.clamp(_polarLimit, math.pi - _polarLimit);
      notifyListeners();
      return;
    }

    // The Google-Earth swoop: a flight across the scene climbs before it
    // descends, so the journey reads as travel rather than a teleport.
    final travel = (target - _target).length;
    final overview = math.max(_distance, distance);
    final swoop = travel > overview * 0.6
        ? math.min(travel * 0.5, maxDistance - overview)
        : 0.0;

    _flight = _Flight(
      fromTarget: _target.clone(),
      toTarget: target.clone(),
      fromDistance: _distance,
      toDistance: distance,
      fromTheta: _theta,
      toTheta: endTheta,
      fromPhi: _phi,
      toPhi: phi.clamp(_polarLimit, math.pi - _polarLimit),
      durationMs: durationMs.toDouble(),
      swoop: swoop,
    );
    _wake();
  }

  /// Cancels a flight and any coasting motion. A user gesture always outranks
  /// an animation.
  void stop() {
    _flight = null;
    _thetaDelta = 0;
    _phiDelta = 0;
    _thetaVelocity = 0;
    _phiVelocity = 0;
    _panDelta.setZero();
    _sleep();
  }

  /// Drag delta in logical pixels. [viewportHeight] normalizes it, so the same
  /// gesture turns the scene by the same angle whatever the window size.
  void rotate(double dx, double dy, double viewportHeight) {
    if (viewportHeight <= 0) return;
    _flight = null;
    _thetaDelta -= 2 * math.pi * dx / viewportHeight * rotateSpeed;
    _phiDelta -= 2 * math.pi * dy / viewportHeight * rotateSpeed;
    _wake();
  }

  /// Hands the camera the pointer velocity left over at the end of a drag
  /// (logical px/s): the scene keeps turning and eases out instead of
  /// stopping dead under the finger.
  void fling(double vx, double vy, double viewportHeight) {
    if (viewportHeight <= 0) return;
    _thetaVelocity = -2 * math.pi * vx / viewportHeight * rotateSpeed;
    _phiVelocity = -2 * math.pi * vy / viewportHeight * rotateSpeed;
    // Ignore the twitch at the end of a deliberate stop.
    if (_thetaVelocity.abs() < 0.15 && _phiVelocity.abs() < 0.15) {
      _thetaVelocity = 0;
      _phiVelocity = 0;
      return;
    }
    _wake();
  }

  /// The world point under a screen position (offset from the viewport
  /// centre, y down), taken on the plane through the current target
  /// perpendicular to the view axis — the reference surface zooming and
  /// double-taps anchor to.
  Vector3 worldAtScreen(double dx, double dy, double viewportHeight) {
    final tangent = math.tan(kFovRadians / 2);
    final perspective = 0.5 / tangent * viewportHeight;
    final scale = perspective / _distance; // px per world unit at the target
    final (right, up) = _screenAxes;
    return _target + right * (dx / scale) - up * (dy / scale);
  }

  /// Zooms by [factor] keeping [about] fixed on screen: the eye moves along
  /// the eye→[about] line, which is what makes pinch feel anchored to the
  /// fingers instead of sliding toward the centre.
  void zoomAbout(double factor, Vector3 about) {
    final next = (_distance * factor).clamp(minDistance, maxDistance);
    final actual = next / _distance;
    if (actual == 1) return;
    _flight = null;
    _target = about + (_target - about) * actual;
    _distance = next;
    notifyListeners();
  }

  /// The double-tap step: a short animated dive toward [about].
  void zoomTowards(Vector3 about, {double factor = 0.55, int durationMs = 450}) {
    final next = (_distance * factor).clamp(minDistance, maxDistance);
    final actual = next / _distance;
    _flyTo(
      target: about + (_target - about) * actual,
      distance: next,
      theta: _theta,
      phi: _phi,
      durationMs: durationMs,
    );
  }

  /// Tilts the horizon: two-finger vertical drag, Google-Earth style.
  void tilt(double dy, double viewportHeight) {
    if (viewportHeight <= 0) return;
    _flight = null;
    _phiDelta -= 2 * math.pi * dy / viewportHeight * 0.35;
    _wake();
  }

  /// Twist gesture: rotate the azimuth directly by [radians].
  void twist(double radians) {
    _flight = null;
    _theta += radians;
    notifyListeners();
  }

  /// Slides the target in the camera's screen plane, tracking the pointer.
  void pan(double dx, double dy, double viewportHeight) {
    if (viewportHeight <= 0) return;
    _flight = null;
    // How many world units one pixel covers at the target's depth.
    final scale = 2 * _distance * math.tan(kFovRadians / 2) / viewportHeight;
    final (right, up) = _screenAxes;
    _panDelta += right * (-dx * scale) + up * (dy * scale);
    _wake();
  }

  /// [factor] > 1 pushes the camera away, < 1 pulls it in.
  void zoomBy(double factor) {
    final next = (_distance * factor).clamp(minDistance, maxDistance);
    if (next == _distance) return;
    _flight = null;
    _distance = next;
    notifyListeners();
  }

  void reset() =>
      frame(_home, _tetherRadius, halfExtent: _homeHalfExtent);

  void _wake() {
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _sleep() {
    if (_ticker.isActive) _ticker.stop();
    _lastTick = Duration.zero;
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastTick).inMicroseconds / 1000;
    _lastTick = elapsed;
    if (dtMs <= 0) return;

    final flight = _flight;
    if (flight != null) {
      flight.elapsedMs += dtMs;
      final t = (flight.elapsedMs / flight.durationMs).clamp(0.0, 1.0);
      final e = exponentialInOut(t);
      _target = flight.fromTarget + (flight.toTarget - flight.fromTarget) * e;
      _distance =
          flight.fromDistance +
          (flight.toDistance - flight.fromDistance) * e +
          flight.swoop * math.sin(math.pi * e);
      _theta = flight.fromTheta + (flight.toTheta - flight.fromTheta) * e;
      _phi = flight.fromPhi + (flight.toPhi - flight.fromPhi) * e;
      if (t >= 1) {
        _flight = null;
        // Nothing else is pending, so do not hold a frame callback open.
        _sleep();
      }
      notifyListeners();
      return;
    }

    // Consume a slice of each pending delta, and shrink what is left. Frame-rate
    // independence would need a pow() here; OrbitControls does neither, and the
    // difference over a 100ms settle is imperceptible.
    _theta += _thetaDelta * dampingFactor;
    _phi = (_phi + _phiDelta * dampingFactor)
        .clamp(_polarLimit, math.pi - _polarLimit);
    _target += _panDelta * dampingFactor;

    final offset = _target - _home;
    if (offset.length > _tetherRadius) {
      _target = _home + offset.normalized() * _tetherRadius;
      _panDelta.setZero();
    }

    _thetaDelta *= 1 - dampingFactor;
    _phiDelta *= 1 - dampingFactor;
    _panDelta *= 1 - dampingFactor;

    if (_idleDriftSpeed != 0) {
      _theta += _idleDriftSpeed * dtMs / 1000;
    }

    if (_thetaVelocity != 0 || _phiVelocity != 0) {
      final dt = dtMs / 1000;
      _theta += _thetaVelocity * dt;
      _phi = (_phi + _phiVelocity * dt).clamp(_polarLimit, math.pi - _polarLimit);
      final decay = math.pow(0.5, dt / flingHalfLife).toDouble();
      _thetaVelocity *= decay;
      _phiVelocity *= decay;
      if (_thetaVelocity.abs() < 0.02 && _phiVelocity.abs() < 0.02) {
        _thetaVelocity = 0;
        _phiVelocity = 0;
      }
    }

    if (_idleDriftSpeed == 0 &&
        _thetaVelocity == 0 &&
        _phiVelocity == 0 &&
        _thetaDelta.abs() < _epsilon &&
        _phiDelta.abs() < _epsilon &&
        _panDelta.length < _epsilon) {
      _thetaDelta = 0;
      _phiDelta = 0;
      _panDelta.setZero();
      _sleep();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _Flight {
  _Flight({
    required this.fromTarget,
    required this.toTarget,
    required this.fromDistance,
    required this.toDistance,
    required this.fromTheta,
    required this.toTheta,
    required this.fromPhi,
    required this.toPhi,
    required this.durationMs,
    this.swoop = 0,
  });

  final Vector3 fromTarget;
  final Vector3 toTarget;
  final double fromDistance;
  final double toDistance;
  final double fromTheta;
  final double toTheta;
  final double fromPhi;
  final double toPhi;
  final double durationMs;

  /// Extra altitude at the flight's midpoint.
  final double swoop;
  double elapsedMs = 0;
}
