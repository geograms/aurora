// Disk-cached map tiles (native/desktop). A tile is fetched once, written to
// ~/.local/share/aurora/cache/tiles, and served from disk afterwards — so the
// map keeps working off-grid once an area has been viewed. Integrates with
// Flutter's in-memory ImageCache via the ImageProvider key, so panning back to
// a recent tile is instant and re-opening the app reads from disk, not the net.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

ImageProvider tileImageProvider(String url) => _DiskTile(url);

String _cacheDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home/.local/share/aurora/cache/tiles';
}

class _DiskTile extends ImageProvider<_DiskTile> {
  final String url;
  _DiskTile(this.url);

  @override
  Future<_DiskTile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_DiskTile>(this);

  @override
  ImageStreamCompleter loadImage(_DiskTile key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final name = sha256.convert(utf8.encode(url)).toString();
    final file = File('${_cacheDir()}/$name.tile');

    // 1) disk cache
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
        }
      }
    } catch (_) {/* fall through to network */}

    // 2) network, then persist for next time / off-grid
    final resp = await http.get(Uri.parse(url));
    final bytes = resp.bodyBytes;
    if (resp.statusCode == 200 && bytes.isNotEmpty) {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      } catch (_) {/* cache write is best-effort */}
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    }
    throw NetworkImageLoadException(
        statusCode: resp.statusCode, uri: Uri.parse(url));
  }

  @override
  bool operator ==(Object other) => other is _DiskTile && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
