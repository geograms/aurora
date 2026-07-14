import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'link_layer.dart';
import 'model.dart';
import 'scene/card_bakery.dart';
import 'scene/crowd_painter.dart';
import 'scene/projection.dart';
import 'scene/sprite.dart';
import 'scene/sprite_crowd_painter.dart';
import 'scene_controller.dart';

/// What a live card needs to know to draw itself.
class CardState {
  const CardState({
    required this.alpha,
    required this.emphasis,
    required this.glow,
    required this.hovered,
  });

  final double alpha;
  final CardEmphasis emphasis;
  final bool glow;
  final bool hovered;
}

/// The 3D scene: link layer under a baked card crowd under one or two live
/// widget cards, with the orbit-camera gestures and manual picking.
///
/// This is only the scene — panels, menus and keyboard shortcuts belong to
/// the app around it.
class Graph3DView<T> extends StatefulWidget {
  /// The card pipeline: nodes are baked 120x160 textures drawn as perspective
  /// quads; the selected and hovered cards render as live widgets.
  const Graph3DView({
    super.key,
    required this.controller,
    required CardBakery<T> this.bakery,
    required this.liveCardBuilder,
    this.visibleEdgesOf,
    this.onNodeTap,
    this.onBackgroundDoubleTap,
    this.initialReframe = true,
  }) : spriteOf = null,
       fog = const FogStyle(enabled: false);

  /// The sprite pipeline: nodes are screen-facing glow orbs described by
  /// [spriteOf], with depth fog. No live-widget overlay exists — an orb's
  /// glow is a gradient, so nothing needs the widget escape hatch; detail
  /// panels are the app's business.
  const Graph3DView.sprites({
    super.key,
    required this.controller,
    required NodeSprite Function(SceneNode<T> node) this.spriteOf,
    this.fog = const FogStyle(),
    this.visibleEdgesOf,
    this.onNodeTap,
    this.onBackgroundDoubleTap,
    this.initialReframe = true,
  }) : bakery = null,
       liveCardBuilder = null;

  final GraphSceneController<T> controller;
  final CardBakery<T>? bakery;

  /// Builds the widget for a card rendered live (selected or hovered). It is
  /// drawn under the card's perspective transform at 120x160 logical size.
  final Widget Function(
    BuildContext context,
    SceneNode<T> node,
    CardState state,
  )?
  liveCardBuilder;

  /// Sprite-mode descriptor; null in card mode.
  final NodeSprite Function(SceneNode<T> node)? spriteOf;

  /// Sprite-mode depth fog.
  final FogStyle fog;

  /// Filters which edges draw this frame. Defaults to all of the scene's
  /// edges; apps use this to show, say, only the focused node's links.
  final ({List<SceneEdge> edges, List<double> periods}) Function()?
  visibleEdgesOf;

  /// What a tap on a node does. Defaults to the controller's select/deselect
  /// toggle; apps override it for richer semantics (expanding a cluster).
  final void Function(int id)? onNodeTap;

  /// Defaults to the Google-Earth move: an animated zoom step toward the
  /// tapped point. Override to repurpose the gesture.
  final VoidCallback? onBackgroundDoubleTap;

  /// Whether the view re-frames the scene once it learns the viewport's
  /// aspect ratio. Turn off when the app owns the camera (custom vantage
  /// points, cluster fly-overs) — it should then re-frame itself after the
  /// first frame.
  final bool initialReframe;

  @override
  State<Graph3DView<T>> createState() => _Graph3DViewState<T>();
}

class _Graph3DViewState<T> extends State<Graph3DView<T>> {
  GraphSceneController<T> get _controller => widget.controller;

  double _viewportHeight = 1;
  double _lastScale = 1;
  double _lastTwist = 0;
  int _gesturePointers = 1;
  Offset _lastTapDown = Offset.zero;
  Size _sceneSize = const Size(1, 1);
  int? _lastHoverId;

  /// The controller frames the scene before it knows the viewport's shape.
  /// Once the first layout pass has, re-frame so the layout actually fits.
  bool _framed = false;

  Projector _projector(double perspective) => Projector(
    view: _controller.camera.viewMatrix,
    perspective: perspective,
  );

  /// Ids rendered as live widgets above the baked crowd, back to front. They
  /// are also the ones a pick must test first.
  List<int> get _liveIds => <int>[
    if (_controller.hoveredId != null &&
        _controller.hoveredId != _controller.selectedId)
      _controller.hoveredId!,
    if (_controller.selectedId != null) _controller.selectedId!,
  ];

  int? _pickAt(Offset position) {
    _controller.advancePoses();
    final spriteOf = widget.spriteOf;
    if (spriteOf != null) {
      return pickSprite(
        poses: _controller.poses,
        radiusOf: (index) => spriteOf(_controller.renderNodes[index]).radius,
        projector: _projector(perspectiveFor(_sceneSize.height)),
        size: _sceneSize,
        position: position,
        onTop: _liveIds.reversed,
      );
    }
    return pickCard(
      poses: _controller.poses,
      projector: _projector(perspectiveFor(_sceneSize.height)),
      size: _sceneSize,
      position: position,
      onTop: _liveIds.reversed,
    );
  }

  void _onTapUp(TapUpDetails details) {
    final id = _pickAt(details.localPosition);
    if (id == null || id > _controller.liveCount) return;
    (widget.onNodeTap ?? _controller.tapNode)(id);
  }

  void _updateHover(Offset? position) {
    final id = position == null ? null : _pickAt(position);
    if (id == _lastHoverId) return;
    if (_lastHoverId != null) _controller.hoverNode(_lastHoverId!, false);
    if (id != null) _controller.hoverNode(id, true);
    _lastHoverId = id;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Wheel zoom anchors to the cursor, like the pinch does to the fingers.
      _controller.camera.zoomAbout(
        math.exp(event.scrollDelta.dy * 0.001),
        _worldUnder(event.localPosition),
      );
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _lastScale = 1;
    _lastTwist = 0;
    _gesturePointers = details.pointerCount;
    _controller.dragging = true;
    _controller.camera.stop();
  }

  Vector3 _worldUnder(Offset local) {
    final centre = Offset(_sceneSize.width / 2, _sceneSize.height / 2);
    return _controller.camera.worldAtScreen(
      local.dx - centre.dx,
      local.dy - centre.dy,
      _viewportHeight,
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _gesturePointers = details.pointerCount;
    if (details.pointerCount >= 2) {
      final camera = _controller.camera;
      // The Google-Earth two-finger vocabulary, all at once: pinch zooms
      // about the point between the fingers, twisting rotates, dragging
      // vertically tilts the horizon, dragging sideways pans.
      final step = details.scale / _lastScale;
      _lastScale = details.scale;
      if (step > 0 && step != 1) {
        camera.zoomAbout(1 / step, _worldUnder(details.localFocalPoint));
      }
      final twist = details.rotation - _lastTwist;
      _lastTwist = details.rotation;
      camera.twist(twist);
      camera.tilt(details.focalPointDelta.dy, _viewportHeight);
      camera.pan(details.focalPointDelta.dx, 0, _viewportHeight);
    } else {
      _controller.camera.rotate(
        details.focalPointDelta.dx,
        details.focalPointDelta.dy,
        _viewportHeight,
      );
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _controller.dragging = false;
    // A one-finger flick keeps the world turning past finger-up.
    if (_gesturePointers == 1) {
      _controller.camera.fling(
        details.velocity.pixelsPerSecond.dx,
        details.velocity.pixelsPerSecond.dy,
        _viewportHeight,
      );
    }
  }

  void _onDoubleTap() {
    final custom = widget.onBackgroundDoubleTap;
    if (custom != null) {
      custom();
      return;
    }
    _controller.camera.zoomTowards(_worldUnder(_lastTapDown));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: MouseRegion(
        onHover: (event) => _updateHover(event.localPosition),
        onExit: (_) => _updateHover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onTapUp: _onTapUp,
          onDoubleTapDown: (details) => _lastTapDown = details.localPosition,
          onDoubleTap: _onDoubleTap,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _sceneSize = Size(constraints.maxWidth, constraints.maxHeight);
              _viewportHeight = constraints.maxHeight;
              final perspective = perspectiveFor(constraints.maxHeight);
              _controller.camera.aspect =
                  constraints.maxWidth / constraints.maxHeight;

              if (!_framed) {
                _framed = true;
                if (widget.initialReframe) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _controller.reframe(immediate: true),
                  );
                }
              }

              final sceneListenable = Listenable.merge(<Listenable>[
                _controller,
                _controller.camera,
                _controller.transition,
              ]);

              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: Listenable.merge(<Listenable>[
                        sceneListenable,
                        _controller.clock,
                      ]),
                      builder: (context, _) {
                        _controller.advancePoses();
                        final visible =
                            widget.visibleEdgesOf?.call() ??
                            (
                              edges: _controller.edges,
                              periods: _controller.crawlPeriods,
                            );
                        // The crawl clock only needs to run while a crawling
                        // edge is actually on screen.
                        _controller.clock.run(
                          visible.edges.any((edge) => edge.style.crawler),
                        );
                        return CustomPaint(
                          painter: LinkPainter(
                            edges: visible.edges,
                            periods: visible.periods,
                            poses: _controller.poses,
                            projector: _projector(perspective),
                            clockMs: _controller.clock.ms,
                            repaint: _controller.clock,
                          ),
                        );
                      },
                    ),
                  ),
                  // The crowd: baked card quads, or glow-orb sprites.
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: sceneListenable,
                      builder: (context, _) {
                        _controller.advancePoses();
                        final spriteOf = widget.spriteOf;
                        if (spriteOf != null) {
                          // Fog band: the depth range the framed scene spans.
                          final distance = _controller.camera.distance;
                          final radius = _controller.geometry.radius;
                          return CustomPaint(
                            isComplex: true,
                            painter: SpriteCrowdPainter<T>(
                              poses: _controller.poses,
                              nodes: _controller.renderNodes,
                              spriteOf: spriteOf,
                              projector: _projector(perspective),
                              emphasisOf: _controller.emphasisOf,
                              fadeOf: _controller.fadeOf,
                              fog: widget.fog,
                              fogNear: -(distance - radius * 0.4),
                              fogFar: -(distance + radius),
                              style: _controller.style,
                            ),
                          );
                        }
                        final nodes = _controller.renderNodes;
                        final images = List<ui.Image>.generate(
                          nodes.length,
                          (i) => widget.bakery!.imageFor(
                            nodes[i],
                            _controller.alphaOf(i),
                          ),
                        );
                        return CustomPaint(
                          isComplex: true,
                          painter: CardCrowdPainter(
                            poses: _controller.poses,
                            images: images,
                            projector: _projector(perspective),
                            emphasisOf: _controller.emphasisOf,
                            fadeOf: _controller.fadeOf,
                            skip: _liveIds.toSet(),
                            style: _controller.style,
                          ),
                        );
                      },
                    ),
                  ),
                  // Card mode only: the one or two cards that matter render
                  // live — crisp at any zoom, free to carry the glow.
                  if (widget.liveCardBuilder != null)
                    AnimatedBuilder(
                      animation: sceneListenable,
                      builder: (context, _) {
                        _controller.advancePoses();
                        final projector = _projector(perspective);
                        return Stack(
                          fit: StackFit.expand,
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            for (final id in _liveIds)
                              if (projector.depthOf(
                                    _controller.poses[id - 1].position,
                                  ) <=
                                  -1)
                                Center(
                                  key: ValueKey<String>(
                                    _controller.renderNodes[id - 1].key,
                                  ),
                                  child: Transform(
                                    transform: projector.cardMatrix(
                                      _controller.poses[id - 1].matrix,
                                    ),
                                    alignment: Alignment.center,
                                    child: IgnorePointer(
                                      child: widget.liveCardBuilder!(
                                        context,
                                        _controller.renderNodes[id - 1],
                                        CardState(
                                          alpha: _controller.alphaOf(id - 1),
                                          emphasis: _controller.emphasisOf(id),
                                          glow: _controller.glowFor(id),
                                          hovered:
                                              _controller.hoveredId == id,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
