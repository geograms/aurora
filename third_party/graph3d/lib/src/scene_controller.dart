import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import 'link_layer.dart' show buildCrawlPeriods;
import 'model.dart';
import 'profile.dart';
import 'scene/layouts.dart';
import 'scene/orbit_camera.dart';
import 'scene/pose.dart';

/// Each card takes between one and two times this to reach its new pose.
const Duration kBaseTransition = Duration(milliseconds: 1200);
const Duration kMaxTransition = Duration(milliseconds: 2400);

/// How long the pointer must rest on a card before it takes focus.
const Duration kHoverDelay = Duration(milliseconds: 500);

/// A free-running millisecond clock, so crawling balls advance without
/// forcing the card crowd to rebuild.
class LinkClock extends ChangeNotifier {
  LinkClock(TickerProvider vsync) {
    _ticker = vsync.createTicker((elapsed) {
      ms = elapsed.inMicroseconds / 1000;
      notifyListeners();
    });
  }

  late final Ticker _ticker;
  double ms = 0;

  void run(bool active) {
    if (active == _ticker.isActive) return;
    if (active) {
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// Everything the graph view needs to know: which nodes exist, where they
/// are mid-animation, what is selected, hovered or highlighted.
///
/// Nodes are identified two ways. The **key** is durable: selection, hover
/// and the bake cache follow it across scene changes. The **id** (one-based
/// index into [renderNodes]) is a per-frame handle used by the painters and
/// the picker; it is only valid until the next [setScene].
///
/// [setScene] diffs by key: persisting nodes keep their current pose and
/// glide to the new layout, new nodes fly in from [_enterPoseOf], vanished
/// nodes are kept at the tail of the render list while they fly out and fade,
/// then pruned when the transition completes. Keeping exits at the tail means
/// live-node ids never shift mid-animation.
class GraphSceneController<T> extends ChangeNotifier {
  GraphSceneController({
    required TickerProvider vsync,
    this.style = const GraphStyle(),
  }) {
    camera = OrbitCamera(vsync: vsync);
    clock = LinkClock(vsync);
    transition = AnimationController(vsync: vsync, duration: kMaxTransition)
      ..addStatusListener(_onTransitionStatus);
  }

  final GraphStyle style;

  late final OrbitCamera camera;
  late final LinkClock clock;
  late final AnimationController transition;

  final math.Random _random = math.Random(11);

  // --- render state: parallel arrays over renderNodes -----------------------

  List<SceneNode<T>> _live = <SceneNode<T>>[];
  List<SceneNode<T>> _exiting = <SceneNode<T>>[];
  List<SceneNode<T>> _renderNodes = <SceneNode<T>>[];
  Map<String, int> _idByKey = <String, int>{};

  List<SceneEdge> _edges = <SceneEdge>[];
  List<double> _crawlPeriods = <double>[];

  List<Pose> _start = <Pose>[];
  List<Pose> _targets = <Pose>[];
  List<Pose> _current = <Pose>[];
  List<double> _durationsMs = <double>[];
  List<double> _fades = <double>[];
  List<bool> _isExiting = <bool>[];
  List<bool> _isEntering = <bool>[];

  LayoutGeometry _geometry = LayoutGeometry.fromPoses(const <Pose>[]);

  /// Bumped by every [setScene]; a completion prune from a superseded scene
  /// must not fire.
  int _generation = 0;

  String? _selectedKey;
  String? _hoveredKey;
  String? _focusHoverKey;
  Timer? _hoverTimer;
  bool _dragging = false;
  Set<String> _highlightKeys = const <String>{};

  // --- accessors -------------------------------------------------------------

  /// Live nodes followed by any still-exiting nodes. Ids index this list,
  /// one-based.
  List<SceneNode<T>> get renderNodes => _renderNodes;

  /// The count of live (non-exiting) nodes; ids above this are exiting and
  /// take no part in picking or selection.
  int get liveCount => _live.length;

  List<SceneEdge> get edges => _edges;
  List<double> get crawlPeriods => _crawlPeriods;
  List<Pose> get poses => _current;
  LayoutGeometry get geometry => _geometry;

  SceneNode<T>? nodeByKey(String key) {
    final id = _idByKey[key];
    return id == null ? null : _renderNodes[id - 1];
  }

  /// The card's stable background-opacity variation, derived from its key so
  /// it survives scene rebuilds (and so its bake stays valid).
  double alphaOf(int index) => alphaForKey(_renderNodes[index].key);

  static double alphaForKey(String key) =>
      0.25 + (key.hashCode & 0xFFFF) / 0xFFFF * 0.5;

  /// Enter/exit opacity for a node id: 1 once settled.
  double fadeOf(int id) => _fades[id - 1];

  String? get selectedKey => _selectedKey;
  String? get hoveredKey => _hoveredKey;

  /// The node with the user's attention: the hover that has lasted past
  /// [kHoverDelay], else the selection.
  String? get focusKey => _focusHoverKey ?? _selectedKey;

  int? get selectedId => _idOf(_selectedKey);
  int? get hoveredId => _idOf(_hoveredKey);
  int? get focusId => _idOf(focusKey);

  int? _idOf(String? key) => key == null ? null : _idByKey[key];

  /// Keys the app wants lit regardless of selection (search hits, filters).
  set highlightKeys(Set<String> keys) {
    _highlightKeys = keys;
    notifyListeners();
  }

  Set<String> get highlightKeys => _highlightKeys;

  /// Ids linked to [focusId], separated by direction.
  ({List<int> incoming, List<int> outgoing}) linksOf(int id) {
    final incoming = <int>[];
    final outgoing = <int>[];
    for (final edge in _edges) {
      if (edge.isSelfEdge) continue;
      if (edge.from == id) outgoing.add(edge.to);
      if (edge.to == id) incoming.add(edge.from);
    }
    return (incoming: incoming, outgoing: outgoing);
  }

  /// Ids drawn normally; everything else dims. Empty set means no emphasis is
  /// in play and the whole graph reads normally.
  Set<int> get _activeIds {
    final focus = focusId;
    final active = <int>{
      for (final key in _highlightKeys)
        if (_idByKey[key] != null) _idByKey[key]!,
    };
    if (focus != null) {
      final links = linksOf(focus);
      active
        ..add(focus)
        ..addAll(links.incoming)
        ..addAll(links.outgoing);
    }
    return active;
  }

  CardEmphasis emphasisOf(int id) {
    if (id == selectedId) return CardEmphasis.selected;
    final active = _activeIds;
    if (active.isEmpty) return CardEmphasis.normal;
    return active.contains(id)
        ? CardEmphasis.highlighted
        : CardEmphasis.inactive;
  }

  /// Whether this card carries a glow. Glows are per-frame blurs and only the
  /// live (widget-rendered) cards can afford one.
  bool glowFor(int id) => id == selectedId;

  // --- scene changes ----------------------------------------------------------

  /// Replaces the scene. Nodes whose keys persist glide from where they are;
  /// new nodes enter from [enterPoseOf] (default: a far random point, the
  /// classic fly-in); vanished nodes fly to [exitPoseOf] (default: hold
  /// position) while fading, and are pruned when the transition ends.
  void setScene(
    GraphScene<T> scene, {
    required LayoutStrategy<T> layout,
    Pose Function(SceneNode<T> node)? enterPoseOf,
    Pose Function(SceneNode<T> node)? exitPoseOf,
    bool reframe = true,
  }) {
    advancePoses();
    _generation += 1;

    final oldPoseByKey = <String, Pose>{
      for (var i = 0; i < _renderNodes.length; i++)
        _renderNodes[i].key: _current[i],
    };
    final newKeys = <String>{for (final node in scene.nodes) node.key};

    // Exiting = anything on screen whose key vanished — including nodes that
    // were already exiting, which simply continue out under the new scene.
    final exiting = <SceneNode<T>>[
      for (final node in _renderNodes)
        if (!newKeys.contains(node.key)) node,
    ];

    _live = List<SceneNode<T>>.of(scene.nodes);
    _exiting = exiting;
    _renderNodes = <SceneNode<T>>[..._live, ..._exiting];
    _idByKey = <String, int>{
      for (var i = 0; i < _live.length; i++) _live[i].key: i + 1,
    };

    _geometry = layout(_live);

    final count = _renderNodes.length;
    _start = List<Pose>.generate(count, (i) {
      final node = _renderNodes[i];
      final old = oldPoseByKey[node.key];
      if (old != null) return old;
      return enterPoseOf?.call(node) ?? _randomFarPose();
    });
    _targets = List<Pose>.generate(count, (i) {
      if (i < _live.length) return _geometry.poses[i];
      final node = _renderNodes[i];
      return exitPoseOf?.call(node) ?? oldPoseByKey[node.key]!;
    });
    _current = List<Pose>.of(_start);
    _isExiting = List<bool>.generate(count, (i) => i >= _live.length);
    _isEntering = List<bool>.generate(
      count,
      (i) => !_isExiting[i] && !oldPoseByKey.containsKey(_renderNodes[i].key),
    );
    _fades = List<double>.generate(count, (i) => _isEntering[i] ? 0 : 1);
    _durationsMs = List<double>.generate(
      count,
      (_) =>
          kBaseTransition.inMilliseconds +
          _random.nextDouble() * kBaseTransition.inMilliseconds,
    );

    _edges = scene.edges;
    _crawlPeriods = buildCrawlPeriods(scene.edges.length);

    // Selection and hover follow keys; a vanished key releases them.
    if (_selectedKey != null && !newKeys.contains(_selectedKey)) {
      _selectedKey = null;
    }
    if (_hoveredKey != null && !newKeys.contains(_hoveredKey)) {
      _hoveredKey = null;
    }
    if (_focusHoverKey != null && !newKeys.contains(_focusHoverKey)) {
      _focusHoverKey = null;
    }

    _lastAdvanceValue = -1;
    _posesSettled = false;
    transition.forward(from: 0);

    if (reframe) this.reframe();
    notifyListeners();
  }

  /// Re-lays-out the current nodes; a scene change without membership change.
  void setLayout(LayoutStrategy<T> layout) {
    setScene(GraphScene<T>(nodes: _live, edges: _edges), layout: layout);
  }

  Pose _randomFarPose() => Pose(
    Vector3(
      _random.nextDouble() * 4000 - 2000,
      _random.nextDouble() * 4000 - 2000,
      _random.nextDouble() * 4000 - 2000,
    ),
    Quaternion.identity(),
  );

  void _onTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final generation = _generation;
    // Prune outside the paint phase: painters and the picker read the arrays
    // during this frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (generation != _generation) return; // superseded by a newer scene
      _prune();
    });
  }

  void _prune() {
    if (_exiting.isEmpty) return;
    final live = _live.length;
    _exiting = <SceneNode<T>>[];
    _renderNodes = _live;
    _start = _start.sublist(0, live);
    _targets = _targets.sublist(0, live);
    _current = _current.sublist(0, live);
    _durationsMs = _durationsMs.sublist(0, live);
    _fades = _fades.sublist(0, live);
    _isExiting = _isExiting.sublist(0, live);
    _isEntering = _isEntering.sublist(0, live);
    notifyListeners();
  }

  // --- per-frame animation -----------------------------------------------------

  static final ProfileTimer _advanceTimer = ProfileTimer('ADVANCE');
  double _lastAdvanceValue = -1;
  bool _posesSettled = false;

  /// Advances every card towards its target at its own pace. Painters and the
  /// picker call this before reading poses; the guard makes repeat calls in a
  /// frame free, so none of them has to know about the others.
  void advancePoses() {
    if (transition.isCompleted) {
      // The last animated frame lands slightly short of t=1, and a dropped
      // frame can skip the end entirely. Snap once.
      if (_posesSettled) return;
      for (var i = 0; i < _current.length; i++) {
        _current[i] = _targets[i];
        _fades[i] = _isExiting[i] ? 0 : 1;
      }
      _posesSettled = true;
      return;
    }
    _posesSettled = false;
    if (transition.value == _lastAdvanceValue) return;
    _lastAdvanceValue = transition.value;

    _advanceTimer.time(() {
      final elapsedMs = transition.value * kMaxTransition.inMilliseconds;
      for (var i = 0; i < _current.length; i++) {
        final t = (elapsedMs / _durationsMs[i]).clamp(0.0, 1.0);
        final eased = exponentialInOut(t);
        _current[i] = lerpPose(_start[i], _targets[i], eased);
        if (_isExiting[i]) {
          _fades[i] = 1 - eased;
        } else if (_isEntering[i]) {
          _fades[i] = eased;
        }
      }
    });
  }

  // --- camera -------------------------------------------------------------------

  /// Backs the camera off until the whole layout fits the current viewport.
  void reframe({bool immediate = false}) {
    camera.frame(
      _geometry.center,
      _geometry.radius,
      halfExtent: _geometry.halfExtent,
      durationMs: immediate ? 0 : 1500,
    );
  }

  /// Flies to a node's resting pose (not to wherever it is mid-flight).
  void flyToNode(int id) {
    if (id < 1 || id > _live.length) return;
    camera.flyToPose(_geometry.poses[id - 1]);
  }

  // --- selection ------------------------------------------------------------------

  /// What a tap on a card does: pick it, or let go of it if it was already
  /// the current one. Exiting nodes ignore taps.
  void tapNode(int id) {
    if (id < 1 || id > _live.length) return;
    if (_renderNodes[id - 1].key == _selectedKey) {
      clearSelection();
    } else {
      selectNode(id);
    }
  }

  void selectNode(int id) {
    if (id < 1 || id > _live.length) return;
    _hoverTimer?.cancel();
    _focusHoverKey = null;
    _selectedKey = _renderNodes[id - 1].key;
    flyToNode(id);
    notifyListeners();
  }

  void clearSelection() {
    _hoverTimer?.cancel();
    _focusHoverKey = null;
    _selectedKey = null;
    notifyListeners();
  }

  void hoverNode(int id, bool entered) {
    if (_dragging) return;
    if (id < 1 || id > _live.length) return;
    final key = _renderNodes[id - 1].key;
    _hoverTimer?.cancel();

    if (entered) {
      if (_hoveredKey == key && _focusHoverKey == key) return;
      _hoveredKey = key;
      notifyListeners();
      _hoverTimer = Timer(kHoverDelay, () {
        // Resolved at fire time: the scene may have changed under the timer.
        if (_idByKey.containsKey(key)) {
          _focusHoverKey = key;
          notifyListeners();
        }
      });
    } else {
      if (_hoveredKey != key) return;
      _hoveredKey = null;
      notifyListeners();
      _hoverTimer = Timer(kHoverDelay, () {
        _focusHoverKey = null;
        notifyListeners();
      });
    }
  }

  /// Whether a camera gesture is in flight — apps use it to get their HUD
  /// out of the way.
  bool get isDragging => _dragging;

  /// A drag suppresses hover, so focus does not flicker through every card
  /// the pointer sweeps across.
  set dragging(bool value) {
    if (_dragging == value) return;
    _dragging = value;
    if (value) {
      _hoverTimer?.cancel();
      _hoveredKey = null;
      _focusHoverKey = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    transition.dispose();
    clock.dispose();
    camera.dispose();
    super.dispose();
  }
}
