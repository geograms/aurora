import 'dart:ui';

import 'package:flutter/foundation.dart';

/// One node in the scene, wrapping the consumer's own data type.
///
/// The [key] is the node's durable identity: it survives scene rebuilds, keys
/// the baked-image cache, and carries selection and hover across
/// expand/collapse. The engine never inspects [data]; it only hands it back
/// to the consumer's paint and build callbacks.
@immutable
class SceneNode<T> {
  const SceneNode({required this.key, required this.data});

  final String key;
  final T data;
}

/// How one edge is drawn.
@immutable
class EdgeStyle {
  const EdgeStyle({
    this.color = const Color(0xFF016161),
    this.width = 1,
    this.label,
    this.crawler = true,
    this.glow = false,
    this.dashed = false,
    this.ticks = 0,
    this.pulseCount = 1,
    this.offsetPx = 0,
  });

  final Color color;
  final double width;

  /// Drawn at the projected midpoint of the edge, e.g. an interface name.
  final String? label;

  /// Whether pulses crawl from [SceneEdge.from] to [SceneEdge.to].
  final bool crawler;

  /// A wide, faint under-stroke beneath the bright line: cheap bloom.
  final bool glow;

  /// Ghost style, for path segments whose middle is unknowable.
  final bool dashed;

  /// Small perpendicular marks along the edge — one per unknown intermediate
  /// hop on a ghost segment.
  final int ticks;

  /// How many phase-offset pulses crawl the edge when [crawler] is on.
  final int pulseCount;

  /// Screen-space perpendicular shift, so several edges between the same two
  /// nodes (one per shared network) render as parallel lines instead of
  /// stacking invisibly.
  final double offsetPx;
}

/// A directed edge between two nodes of the current scene.
///
/// Endpoints are one-based indices into the scene's node list — the same
/// per-frame id handed to the pick and emphasis callbacks. Durable identity
/// belongs to keys; edges are rebuilt with each scene.
@immutable
class SceneEdge {
  const SceneEdge(this.from, this.to, {this.style = const EdgeStyle()});

  final int from;
  final int to;
  final EdgeStyle style;

  bool get isSelfEdge => from == to;
  bool touches(int id) => from == id || to == id;
}

/// What the engine renders: nodes plus the edges between them.
@immutable
class GraphScene<T> {
  const GraphScene({required this.nodes, this.edges = const <SceneEdge>[]});

  final List<SceneNode<T>> nodes;
  final List<SceneEdge> edges;
}

/// How prominently a card is drawn, given what is selected or highlighted.
enum CardEmphasis {
  /// The current node: fully opaque, drawn in front of everything.
  selected,

  /// Related to the focus — linked to it, or in the highlight set.
  highlighted,

  /// Nothing has focus, so everything reads normally.
  normal,

  /// Dimmed out of the way while something else has the user's attention.
  inactive,
}

/// Engine-level draw constants a consumer may retheme.
@immutable
class GraphStyle {
  const GraphStyle({
    this.highlightBorder = const Color.fromRGBO(127, 255, 255, 0.75),
    this.inactiveAlpha = 0.16,
  });

  /// Stroked around cards with [CardEmphasis.highlighted].
  final Color highlightBorder;

  /// Alpha a [CardEmphasis.inactive] card's image is drawn with.
  final double inactiveAlpha;
}
