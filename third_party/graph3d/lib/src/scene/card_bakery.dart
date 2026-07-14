import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../model.dart';
import 'projection.dart';

/// Paints one card's content onto [canvas] in card-local coordinates:
/// origin top-left, 120x160 logical units (kCardWidth x kCardHeight).
///
/// Called once per node — the result is baked to a GPU texture and reused
/// every frame, so this may be as elaborate as a widget build. [alpha] is the
/// node's stable per-key opacity variation (the original CSS3D look gave each
/// card a random background alpha).
typedef CardPaint<T> = void Function(Canvas canvas, T data, double alpha);

/// Rasterizes cards on demand into GPU-resident images, keyed by node key.
///
/// This exists because Flutter re-rasterizes anything under a perspective
/// transform on every frame — the raster cache is disabled there, and Android
/// has no partial repaint. A crowd of widget cards costs 20-30ms of raster per
/// animated frame on a low-end phone, all of it glyph drawing. A baked card
/// is one textured quad; hundreds of them raster in a few milliseconds.
///
/// The cache is LRU-bounded so a scene that keeps introducing nodes (cluster
/// expansion, live networks) cannot grow texture memory without limit. At the
/// default 1.5x a card costs ~175KB of texture; at 1x, ~77KB.
class CardBakery<T> {
  CardBakery({
    required CardPaint<T> paint,
    double Function(T data)? scaleOf,
    this.maxEntries = 1024,
  }) : _paint = paint,
       _scaleOf = scaleOf;

  final CardPaint<T> _paint;

  /// Oversampling factor per node. Cards in the crowd render at well under
  /// their natural size, so 1.5x keeps them crisp through a deep zoom; bulk
  /// nodes (cluster leaves) can return 1.0 to halve their texture bill.
  final double Function(T data)? _scaleOf;

  final int maxEntries;

  final LinkedHashMap<String, ui.Image> _cache =
      LinkedHashMap<String, ui.Image>();

  int get length => _cache.length;

  /// The baked image for [node], rasterizing it now if it is not cached.
  ///
  /// `toImageSync` returns immediately with a GPU-backed image; the actual
  /// rasterization happens off the UI thread.
  ui.Image imageFor(SceneNode<T> node, double alpha) {
    final cached = _cache.remove(node.key);
    if (cached != null) {
      _cache[node.key] = cached; // re-insert: most recently used
      return cached;
    }

    final scale = _scaleOf?.call(node.data) ?? 1.5;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    _paint(canvas, node.data, alpha);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (kCardWidth * scale).round(),
      (kCardHeight * scale).round(),
    );
    picture.dispose();

    _cache[node.key] = image;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first)!.dispose();
    }
    return image;
  }

  /// Drops a stale bake, e.g. when the node's data changed.
  void evict(String key) => _cache.remove(key)?.dispose();

  /// Drops every bake whose key matches, e.g. a collapsed cluster's leaves.
  void evictWhere(bool Function(String key) test) {
    final doomed = _cache.keys.where(test).toList();
    for (final key in doomed) {
      _cache.remove(key)!.dispose();
    }
  }

  void dispose() {
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }
}
