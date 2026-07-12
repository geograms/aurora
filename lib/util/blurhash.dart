/// Minimal blurhash decoder (https://blurha.sh) — pure Dart, no dependency.
/// NOSTR NIP-92 `imeta` tags carry a blurhash for images/videos so a feed can
/// paint a soft placeholder before (or instead of) downloading anything.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

const _chars =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#\$%*+,-.:;=?@[]^_{|}~';

int _b83(String s) {
  var v = 0;
  for (var i = 0; i < s.length; i++) {
    final k = _chars.indexOf(s[i]);
    if (k < 0) return -1;
    v = v * 83 + k;
  }
  return v;
}

double _srgbToLinear(int v) {
  final x = v / 255.0;
  return x <= 0.04045
      ? x / 12.92
      : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
}

int _linearToSrgb(double v) {
  final x = v.clamp(0.0, 1.0);
  final s =
      x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1 / 2.4) - 0.055;
  return (s * 255 + 0.5).floor().clamp(0, 255);
}

double _signPow(double v, double e) =>
    (v < 0 ? -1 : 1) * math.pow(v.abs(), e).toDouble();

/// Decode [hash] into [w]x[h] RGBA pixels, or null on malformed input.
/// Keep w/h small (e.g. 32x32) — it's a blur, the GPU upscales it fine.
Uint8List? blurhashPixels(String hash, int w, int h) {
  if (hash.length < 6) return null;
  final sizeFlag = _b83(hash[0]);
  if (sizeFlag < 0) return null;
  final ny = (sizeFlag ~/ 9) + 1;
  final nx = (sizeFlag % 9) + 1;
  if (hash.length != 4 + 2 * nx * ny) return null;
  final quantMax = _b83(hash[1]);
  if (quantMax < 0) return null;
  final maxVal = (quantMax + 1) / 166.0;

  final colors = List<List<double>>.generate(nx * ny, (_) => [0, 0, 0]);
  // DC (average color).
  final dc = _b83(hash.substring(2, 6));
  if (dc < 0) return null;
  colors[0] = [
    _srgbToLinear(dc >> 16),
    _srgbToLinear((dc >> 8) & 255),
    _srgbToLinear(dc & 255),
  ];
  // AC components.
  for (var i = 1; i < nx * ny; i++) {
    final v = _b83(hash.substring(4 + i * 2, 6 + i * 2));
    if (v < 0) return null;
    colors[i] = [
      _signPow((v ~/ (19 * 19) - 9) / 9.0, 2.0) * maxVal,
      _signPow(((v ~/ 19) % 19 - 9) / 9.0, 2.0) * maxVal,
      _signPow((v % 19 - 9) / 9.0, 2.0) * maxVal,
    ];
  }

  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var j = 0; j < ny; j++) {
        final cy = math.cos(math.pi * y * j / h);
        for (var i = 0; i < nx; i++) {
          final basis = math.cos(math.pi * x * i / w) * cy;
          final c = colors[j * nx + i];
          r += c[0] * basis;
          g += c[1] * basis;
          b += c[2] * basis;
        }
      }
      final o = (y * w + x) * 4;
      out[o] = _linearToSrgb(r);
      out[o + 1] = _linearToSrgb(g);
      out[o + 2] = _linearToSrgb(b);
      out[o + 3] = 255;
    }
  }
  return out;
}

/// Decode [hash] straight to a [ui.Image] (async pixel upload).
Future<ui.Image?> blurhashImage(String hash, {int w = 32, int h = 32}) {
  final px = blurhashPixels(hash, w, h);
  if (px == null) return Future.value(null);
  final c = Completer<ui.Image?>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}
