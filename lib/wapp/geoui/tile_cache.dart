// Cross-platform map-tile image provider: a disk-backed cache on native
// (desktop/mobile) for off-grid use, and a plain NetworkImage on web.

import 'package:flutter/widgets.dart';

import 'tile_cache_web.dart' if (dart.library.io) 'tile_cache_io.dart' as impl;

/// An ImageProvider for a tile URL that caches to disk where possible.
ImageProvider tileImageProvider(String url) => impl.tileImageProvider(url);
