// Web fallback for map tiles: the browser already caches network images, so
// we just hand back a plain NetworkImage (no dart:io disk cache on web).

import 'package:flutter/widgets.dart';

ImageProvider tileImageProvider(String url) => NetworkImage(url);
