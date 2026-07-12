import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../media_disk_cache.dart';
import 'hero_item.dart';

/// Is the hero image BRIGHT exactly where the text sits?
///
/// White bold text over a photo is readable until the photo happens to be a snow
/// field, a whiteboard, or an overexposed sky — and then the headline vanishes.
/// The bottom scrim helps, but it cannot be dark enough to fix the worst case
/// without ruining every other card by dimming the picture.
///
/// So: measure. Decode a TINY copy of the image (32px wide — a few hundred
/// bytes of pixels), take the mean luminance of the region the title and summary
/// actually occupy, and let the card decide whether to put a plate behind them.
/// Measured once per item and cached; the verdict cannot change for a given
/// image, so this never repeats.
class HeroBrightness {
  HeroBrightness._();
  static final HeroBrightness instance = HeroBrightness._();

  /// item id -> is the text zone bright enough to need a plate
  final Map<String, bool> _verdict = {};
  final Set<String> _inFlight = {};

  /// Bumped when a verdict lands, so the carousel can rebuild the one card that
  /// changed instead of polling.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Above this mean luminance (0..1), white text stops being safe.
  static const double _brightEnough = 0.58;

  /// The text zone: the bottom 45% of the card, left of the stats pill.
  static const double _zoneTop = 0.55;
  static const double _zoneRight = 0.78;

  /// Null until measured. Callers render without a plate meanwhile — a plate
  /// that pops in late is worse than one that never appears on a dark photo.
  bool? verdictFor(HeroItem item) => _verdict[item.id];

  /// Fire-and-forget. Safe to call on every build: it de-duplicates.
  void probe(HeroItem item) {
    final url = item.imageUrl;
    if (_verdict.containsKey(item.id) || _inFlight.contains(item.id)) return;
    if (url == null && item.thumbnail == null) return; // gradient card: no photo
    _inFlight.add(item.id);
    unawaited(_measure(item));
  }

  Future<void> _measure(HeroItem item) async {
    try {
      final bytes = await _bytesFor(item);
      if (bytes == null || bytes.isEmpty) return;
      final bright = await _isBright(bytes);
      if (bright == null) return;
      _verdict[item.id] = bright;
      revision.value++;
    } catch (_) {
      // A card that cannot be measured simply keeps the normal scrim.
    } finally {
      _inFlight.remove(item.id);
    }
  }

  Future<Uint8List?> _bytesFor(HeroItem item) async {
    final url = item.imageUrl;
    if (url == null) return item.thumbnail;
    // Already mirrored into the archive (a followed author's picture).
    if (url.startsWith('file:')) {
      return sharedMediaArchive()?.get(url) ?? item.thumbnail;
    }
    if (url.startsWith('http')) {
      // The card is displaying this image anyway, so it is already in the disk
      // cache by the time we ask — this is a read, not a second download.
      final b = await MediaDiskCache.instance.fetch(url, maxBytes: 8 * 1024 * 1024);
      return b ?? item.thumbnail;
    }
    return item.thumbnail;
  }

  /// Decode small and average the luminance of the text zone.
  ///
  /// 32px wide is deliberate: the question is "is this area pale", which a
  /// thumbnail answers as well as a full decode, at a thousandth of the cost.
  /// A full-size decode here would compete with the carousel for frames.
  static Future<bool?> _isBright(Uint8List bytes) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 32);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null || w == 0 || h == 0) return null;

      final px = data.buffer.asUint8List();
      final y0 = (h * _zoneTop).floor();
      final x1 = (w * _zoneRight).ceil();
      var sum = 0.0;
      var n = 0;
      for (var y = y0; y < h; y++) {
        for (var x = 0; x < x1; x++) {
          final i = (y * w + x) * 4;
          if (i + 2 >= px.length) continue;
          // Rec. 709 luma — green dominates perceived brightness, and a filter
          // that averaged R,G,B would call a saturated blue sky "bright".
          sum += (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255;
          n++;
        }
      }
      if (n == 0) return null;
      return (sum / n) >= _brightEnough;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
    }
  }
}
