/* Aurora · GeoUI media widgets (APRX.md §16 media references)
 *
 * Reusable, wapp-agnostic rendering for `file:<sha256>.<ext>` tokens:
 *
 *   MediaThumbnail — a compact preview card for one token, resolved against
 *     the device's shared MediaArchive. Shows the stored screenshot (or
 *     decodes the image bytes directly), a play overlay for video/audio, or
 *     a file chip for generic attachments / unknown hashes. Tapping opens
 *     MediaViewerPage.
 *
 *   MediaViewerPage — the full-size view: pinch-zoom image, a native video
 *     player through the `media.video` capability when a backend + the
 *     mediapack wapp are present (graceful fallback otherwise), and a
 *     details card for everything else.
 *
 * Any wapp using the generic chat widgets gets these for free — the host
 * spots the tokens in message text (media_ref.dart) and renders them here.
 * No transport: an unknown hash renders as a chip stating the media is not
 * in the local archive (fetching is future work, APRX §16.5).
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../profile/storage_paths.dart';
import '../../../services/preferences_service.dart';
import '../../../util/media_archive.dart';
import '../../../util/media_ref.dart';
import '../../native/media_capability.dart';

/// The device's shared media archive (devices/&lt;id&gt;/data/media.sqlite3),
/// or null when storage isn't ready (e.g. web).
MediaArchive? sharedMediaArchive() {
  if (kIsWeb) return null;
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return null;
  return MediaArchive.forStorage(wappsDataStorage(prefs));
}

/// Compact preview card for one media token inside a chat bubble.
class MediaThumbnail extends StatelessWidget {
  final MediaRef ref;
  const MediaThumbnail({super.key, required this.ref});

  static const double _w = 200, _h = 140;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final archive = sharedMediaArchive();
    final meta = archive?.getMeta(ref.sha256);

    // Not in the local archive → an inert "media not available" chip (the
    // token itself still reached the user as text upstream).
    if (archive == null || meta == null) {
      return _chip(
        cs,
        icon: Icons.help_outline,
        title: 'media not available',
        subtitle: '.${ref.ext} · not in local archive',
      );
    }

    // Preview bytes: the stored screenshot wins; otherwise images decode
    // their own (small) data directly.
    Uint8List? preview = archive.getScreenshot(ref.sha256);
    if (preview == null && ref.kind == MediaKind.image) {
      preview = archive.get(ref.sha256);
    }

    final Widget inner;
    if (preview != null) {
      inner = Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            preview,
            fit: BoxFit.cover,
            cacheWidth: (_w * 2).toInt(),
            errorBuilder: (_, __, ___) => _iconBox(cs),
          ),
          if (ref.kind == MediaKind.video || ref.kind == MediaKind.audio)
            const Center(
              child: CircleAvatar(
                radius: 22,
                backgroundColor: Colors.black54,
                child: Icon(Icons.play_arrow, color: Colors.white, size: 30),
              ),
            ),
        ],
      );
    } else if (ref.kind == MediaKind.video || ref.kind == MediaKind.audio) {
      inner = _iconBox(cs,
          icon: ref.kind == MediaKind.video
              ? Icons.play_circle_outline
              : Icons.audiotrack);
    } else {
      // Generic attachment — a chip is friendlier than an empty frame.
      return InkWell(
        onTap: () => MediaViewerPage.open(context, ref),
        borderRadius: BorderRadius.circular(10),
        child: _chip(
          cs,
          icon: Icons.insert_drive_file_outlined,
          title: meta.name ?? 'file.${meta.ext}',
          subtitle: '.${meta.ext} · ${formatBytes(meta.size)}',
        ),
      );
    }

    return InkWell(
      onTap: () => MediaViewerPage.open(context, ref),
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: _w, height: _h, child: inner),
      ),
    );
  }

  Widget _iconBox(ColorScheme cs, {IconData icon = Icons.broken_image}) =>
      Container(
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(icon, size: 42, color: cs.onSurfaceVariant),
      );

  Widget _chip(ColorScheme cs,
      {required IconData icon, required String title, String? subtitle}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(160),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              if (subtitle != null)
                Text(subtitle,
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Full-size media view: zoomable image, capability-backed video player, or
/// a details card. Pushed as a full route so it gets its own back arrow.
class MediaViewerPage extends StatefulWidget {
  final MediaRef mediaRef;
  const MediaViewerPage({super.key, required this.mediaRef});

  static void open(BuildContext context, MediaRef ref) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MediaViewerPage(mediaRef: ref)));
  }

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  MediaSession? _session;
  File? _tempVideo;

  MediaRef get _ref => widget.mediaRef;

  @override
  void initState() {
    super.initState();
    if (_ref.kind == MediaKind.video || _ref.kind == MediaKind.audio) {
      _startPlayback();
    }
  }

  /// The capability player opens paths, not bytes: stage the archive blob in
  /// a temp file and hand it over. No backend → stays null (fallback UI).
  Future<void> _startPlayback() async {
    final data = sharedMediaArchive()?.get(_ref.sha256);
    if (data == null) return;
    final session = MediaCapabilities.newSession();
    if (session == null) return;
    try {
      final dir = await Directory.systemTemp.createTemp('aurora_media_');
      final f = File('${dir.path}/${_ref.sha256}.${_ref.ext}');
      await f.writeAsBytes(data, flush: true);
      session.open(f.path);
      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _tempVideo = f;
      });
    } catch (_) {
      session.dispose();
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    try {
      _tempVideo?.parent.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final archive = sharedMediaArchive();
    final meta = archive?.getMeta(_ref.sha256);
    final title = meta?.name ?? 'file.${_ref.ext}';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(child: _body(archive, meta)),
    );
  }

  Widget _body(MediaArchive? archive, MediaMeta? meta) {
    if (archive == null || meta == null) {
      return _fallback(Icons.help_outline, 'This media is not in the local '
          'archive.\nOnly its reference travelled over the air.');
    }
    switch (_ref.kind) {
      case MediaKind.image:
        final data = archive.get(_ref.sha256);
        if (data == null) {
          return _fallback(Icons.broken_image, 'Image data missing.');
        }
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.memory(data, fit: BoxFit.contain),
        );
      case MediaKind.video:
      case MediaKind.audio:
        final s = _session;
        if (s != null) return s.buildSurface(BoxFit.contain);
        if (!MediaCapabilities.backendAvailable ||
            MediaCapabilities.active == null) {
          // Poster (if any) + the reason playback is unavailable.
          final shot = archive.getScreenshot(_ref.sha256);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shot != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child:
                          Image.memory(shot, width: 320, fit: BoxFit.contain)),
                ),
              _fallback(
                  Icons.play_disabled,
                  'No video backend available.\n'
                  'Install the Mediapack wapp to play media.'),
            ],
          );
        }
        return const CircularProgressIndicator();
      case MediaKind.file:
        return _fallback(
            Icons.insert_drive_file_outlined,
            '${meta.name ?? 'file'}.${meta.ext}\n'
            '${formatBytes(meta.size)}'
            '${meta.description == null ? '' : '\n${meta.description}'}');
    }
  }

  Widget _fallback(IconData icon, String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white38),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
          ],
        ),
      );
}
