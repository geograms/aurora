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

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../profile/storage_paths.dart';
import '../../../services/preferences_service.dart';
import '../../../services/reticulum/rns_service.dart';
import '../../../util/media_archive.dart';
import '../../../util/media_ref.dart';
import '../../shared_media_fetch.dart' show resolveSharedMedia;
import '../../native/wasm_video_player.dart';

/// The device's shared media archive (devices/&lt;id&gt;/data/media.sqlite3),
/// or null when storage isn't ready (e.g. web).
MediaArchive? sharedMediaArchive() {
  if (kIsWeb) return null;
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return null;
  return MediaArchive.forDirectory(wappsDataStorage(prefs).getAbsolutePath(''));
}

/// Compact preview card for one media token inside a chat bubble. While the
/// bytes aren't in the local archive yet it shows a "looking on the network"
/// spinner (a fetch was triggered by the chat for incoming media) and swaps to
/// the image the moment it arrives. Falls back to "not available" only after a
/// long wait with no result.
class MediaThumbnail extends StatefulWidget {
  final MediaRef ref;
  /// Size in bytes from the message's `sz:` hint (so we can show it and decide
  /// whether to auto-download). Null when the sender didn't include it.
  final int? size;
  /// Sender callsign — lets a tap-to-download fetch directly from them over RNS.
  final String? from;
  /// Never auto-download — always show a size + tap-to-download card until the
  /// user taps. Used on the Activity feed, where posts can carry large media the
  /// user should choose to fetch.
  final bool tapOnly;
  /// A tiny PNG preview embedded with the post (`tn:` token). When the full file
  /// isn't local yet, this is shown as the thumbnail so the user sees a preview
  /// WITHOUT downloading; tapping fetches the full-resolution media.
  final Uint8List? inlineThumb;
  const MediaThumbnail(
      {super.key,
      required this.ref,
      this.size,
      this.from,
      this.tapOnly = false,
      this.inlineThumb});

  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<MediaThumbnail> {
  static const double _w = 200, _h = 140;
  // Try actively for 5 minutes, then back off. A thumbnail whose bytes can't be
  // found (the seeder is gone) stops spinning and waits — auto-retrying at most
  // once a day, or immediately when the user taps the retry button. The attempt
  // window is tracked per file hash and shared across every bubble + survives
  // re-renders, so a chat tick (or scrolling the message back into view) doesn't
  // restart the spinner. This is what keeps the icon from rotating forever.
  static const int _windowSec = 300; // active attempt window (5 min)
  static const int _findSec = 60; // give up finding a peer after 1 min (no bytes)
  static const int _cooldownMs = 24 * 60 * 60 * 1000; // auto-retry once a day
  static final Map<String, int> _windowStartMs = {}; // sha256 -> window start ms

  // True once the attempt window ended without ever receiving a byte — i.e. no
  // peer holding this file was reachable. Drives a clear "no peers" card.
  bool _findFailed = false;
  // Highest received-byte count seen + when it last increased (transfer-stall
  // detection: a started transfer that stops making progress is abandoned).
  int _lastReceived = 0;
  int _lastByteMs = 0;

  MediaRef get ref => widget.ref;
  Timer? _poll;
  bool _requested = false; // a tap-to-download was triggered
  bool _playing = false; // video tapped → playing embedded in the stream

  /// Bump when the poster-generation algorithm improves so already-thumbnailed
  /// videos regenerate once with the better picker.
  static const int _thumbAlgoVersion = 3;

  /// sha256 of videos we've tried to thumbnail THIS session (the frequently
  /// rebuilt widget must only kick off one decode per clip).
  static final Set<String> _thumbTried = {};

  /// sha256 of videos whose poster was generated at [_thumbAlgoVersion],
  /// persisted across launches so we neither regenerate every session nor
  /// leave old first-frame posters in place. Loaded once, lazily.
  static Set<String>? _thumbDone;
  static Future<void>? _thumbLoad;

  static Future<void> _loadThumbDone() {
    if (_thumbDone != null) return Future<void>.value();
    return _thumbLoad ??= () async {
      try {
        final j = await activeProfileRoot().readJson('video_thumbs.json');
        _thumbDone = (j != null && (j['algo'] as int?) == _thumbAlgoVersion)
            ? {for (final s in (j['shas'] as List? ?? const [])) s.toString()}
            : <String>{};
      } catch (_) {
        _thumbDone = <String>{};
      }
    }();
  }

  static Future<void> _persistThumbDone() async {
    try {
      await activeProfileRoot().writeJson('video_thumbs.json',
          {'algo': _thumbAlgoVersion, 'shas': _thumbDone!.toList()});
    } catch (_) {}
  }

  /// Generate an attractive poster (best of the first frames) for a video and
  /// persist it as the archive screenshot (reused forever), then refresh to
  /// show it. Upgrades older first-frame posters too (via [_thumbAlgoVersion]).
  Future<void> _ensureVideoThumb(MediaArchive archive) async {
    final sha = ref.sha256;
    if (_thumbTried.contains(sha)) return;
    await _loadThumbDone();
    if (_thumbDone!.contains(sha)) return; // already at the current algo
    final bytes = archive.get(sha);
    if (bytes == null) return; // bytes not local yet — nothing to decode
    _thumbTried.add(sha);
    final png = await WasmVideoThumbnailer.generate(bytes, ref.ext);
    _thumbDone!.add(sha); // record even on failure so we don't retry forever
    unawaited(_persistThumbDone());
    if (png != null) {
      archive.setScreenshot(sha, png);
      if (mounted) setState(() => _preview = null); // re-read the new poster
    }
  }
  int get _nowMs => DateTime.now().millisecondsSinceEpoch;
  // Decoded-once preview bytes: cached so parent rebuilds (the chat re-renders
  // every tick) reuse the SAME Uint8List → MemoryImage cache hit, no re-decode,
  // no flicker.
  Uint8List? _preview;

  /// True when the file is over the auto-download threshold (or auto-download is
  /// off) — it waits for an explicit tap instead of fetching automatically.
  bool get _tooLargeForAuto {
    final maxMb = PreferencesService.instanceSync?.mediaAutoMaxMb ?? 10;
    if (maxMb <= 0) return true; // auto-download disabled
    final sz = widget.size;
    return sz != null && sz > maxMb * 1024 * 1024;
  }

  @override
  void initState() {
    super.initState();
    final a = sharedMediaArchive();
    final have = a != null && a.getMeta(ref.sha256) != null;
    // Auto-fetching (small/unknown size) → run/resume an attempt window. Large
    // files — and anything in tap-only mode (Activity) — wait for an explicit
    // tap (download chip; no auto window).
    if (!have && !_tooLargeForAuto && !widget.tapOnly) _maybeBeginWindow();
  }

  @override
  void didUpdateWidget(covariant MediaThumbnail old) {
    super.didUpdateWidget(old);
    // If this State gets reused for a DIFFERENT file (list rebuilds can recycle
    // State objects when widgets lack a stable key), drop the cached preview and
    // playback so we don't render the previous file's image for the new ref.
    if (old.ref.sha256 != widget.ref.sha256) {
      _preview = null;
      _playing = false;
      _requested = false;
      _poll?.cancel();
      _poll = null;
      final a = sharedMediaArchive();
      final have = a != null && a.getMeta(ref.sha256) != null;
      if (!have && !_tooLargeForAuto && !widget.tapOnly) _maybeBeginWindow();
    }
  }

  /// Decide whether to (re)start the 5-minute attempt window for this file,
  /// honouring the once-a-day cooldown and resuming a window another bubble for
  /// the same file may already be running.
  void _maybeBeginWindow() {
    final start = _windowStartMs[ref.sha256];
    if (start == null || _nowMs - start >= _cooldownMs) {
      _beginWindow(); // never tried, or last try was over a day ago
    } else if (_nowMs - start < _windowSec * 1000) {
      _startPoll(); // a window is still active → resume polling (no re-fetch)
    }
    // else: window finished and still within the day cooldown → stay idle and
    // show the static "not available" card with its retry button (no spinner).
  }

  /// Start a fresh attempt: actively trigger a fetch and poll for arrival for
  /// the next 5 minutes. The spinner is shown during this window only.
  void _beginWindow() {
    _windowStartMs[ref.sha256] = _nowMs;
    _findFailed = false;
    _lastReceived = 0;
    _lastByteMs = _nowMs;
    // ignore: discarded_futures
    resolveSharedMedia(ref.sha256, ref.ext, fromCallsign: widget.from);
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (t) {
      final arch = sharedMediaArchive();
      if (arch != null && arch.getMeta(ref.sha256) != null) {
        t.cancel(); // complete — the bytes are local now
        if (mounted) setState(() {});
        return;
      }
      final received = _progress()?.received ?? 0;
      if (received > _lastReceived) {
        _lastReceived = received;
        _lastByteMs = _nowMs; // bytes are still flowing
      }
      final start = _windowStartMs[ref.sha256] ?? _nowMs;
      if (received <= 0) {
        // Peer-find phase: no holder has answered yet. Give up after 1 minute so
        // the user isn't left watching an endless spinner; they can tap retry.
        if (_nowMs - start >= _findSec * 1000) {
          t.cancel();
          _findFailed = true;
          if (mounted) setState(() {});
          return;
        }
        // Re-attempt discovery periodically — a holder may come online (the
        // resolve is content-addressed + guarded, so repeats are harmless).
        if (t.tick % 20 == 0) {
          // ignore: discarded_futures
          resolveSharedMedia(ref.sha256, ref.ext, fromCallsign: widget.from);
        }
      } else if (_nowMs - _lastByteMs >= _windowSec * 1000) {
        // Transfer started but stalled (no new bytes for 5 min) — abandon.
        t.cancel();
        _findFailed = true;
        if (mounted) setState(() {});
        return;
      }
      if (mounted) setState(() {});
    });
  }

  /// Current download progress (received bytes; total from the live transfer or,
  /// failing that, the message's `sz:` hint), or null if none yet.
  ({int received, int total})? _progress() {
    final sha = _shaBytes();
    if (sha == null) return null;
    final p = RnsService.instance.fileFetchProgress(sha);
    if (p == null) return null;
    final total = p.total > 0 ? p.total : (widget.size ?? 0);
    return (received: p.received, total: total);
  }

  /// Explicitly fetch a large file the user tapped to download.
  void _download() {
    if (_requested) return;
    _requested = true;
    _beginWindow();
    if (mounted) setState(() {});
  }

  /// User tapped the retry icon on the "not available" card — start a new
  /// attempt window now (resets this file's once-a-day cooldown).
  void _retry() {
    _requested = true;
    _beginWindow();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  String? get _sizeLabel =>
      widget.size == null ? null : formatBytes(widget.size!);

  /// The 32-byte file hash (ref.sha256 is base64url), for the progress lookup.
  Uint8List? _shaBytes() {
    try {
      final b = base64Url.decode('${ref.sha256}=');
      return b.length == 32 ? b : null;
    } catch (_) {
      return null;
    }
  }

  /// A terse "received/total (pct)" label while the bytes stream in over
  /// Reticulum, or null when no transfer progress is available yet.
  // Two lines: a title (phase) + a subtitle (detail). While no bytes have
  // arrived we're still finding a holder (with a 1-min countdown); once bytes
  // flow we show a live percentage + received/total.
  (String, String) _statusLines() {
    final p = _progress();
    final received = p?.received ?? 0;
    final total = p?.total ?? 0;
    if (received <= 0) {
      final start = _windowStartMs[ref.sha256] ?? _nowMs;
      final left = (_findSec - (_nowMs - start) ~/ 1000).clamp(0, _findSec);
      return ('Looking for a peer…', 'no holder yet · ${left}s left');
    }
    if (total > 0) {
      final pct = ((received / total) * 100).clamp(0, 100).round();
      return ('Downloading $pct%',
          '${formatBytes(received)} / ${formatBytes(total)}');
    }
    return ('Downloading…', formatBytes(received));
  }

  // A two-line "finding / downloading" card: spinner + a phase title and a
  // detail line (peer-find countdown, or live percentage + bytes).
  Widget _lookingChip(ColorScheme cs) {
    final (title, sub) = _statusLines();
    return Container(
      width: _w,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(160),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text(sub,
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Static "couldn't find it" card with an explicit retry button — no spinner.
  /// The auto-attempt has finished (it retries on its own at most once a day);
  /// the refresh button forces another look now.
  Widget _notAvailableChip(ColorScheme cs) => Container(
        width: _w,
        padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6, right: 2),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(160),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_findFailed ? Icons.cloud_off : Icons.image_not_supported_outlined,
                size: 22, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_findFailed ? 'No peers have this file' : 'Image not available',
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                  Text(
                      _findFailed
                          ? '${_sizeLabel == null ? '' : '$_sizeLabel · '}none online now · tap retry'
                          : '.${ref.ext} · tap retry to look again',
                      style:
                          TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              tooltip: 'Try downloading again',
              color: cs.primary,
              onPressed: _retry,
            ),
          ],
        ),
      );

  /// Tap-to-download card for a large image we haven't fetched yet.
  Widget _downloadChip(ColorScheme cs) => InkWell(
        onTap: _download,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: _w,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withAlpha(120),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.primary.withAlpha(120), width: 0.7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download, size: 22, color: cs.primary),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Tap to download',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Text(
                        _sizeLabel == null
                            ? '.${ref.ext}'
                            : '$_sizeLabel · .${ref.ext}',
                        style:
                            TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// The embedded `tn:` preview shown as a real thumbnail while the full file
  /// isn't local. A download badge (or live progress when fetching) overlays it;
  /// tapping fetches the full-resolution media.
  Widget _inlinePreview(ColorScheme cs) {
    final fetching = _poll?.isActive ?? false;
    final (title, sub) = fetching ? _statusLines() : ('', '');
    final isClip =
        ref.kind == MediaKind.video || ref.kind == MediaKind.audio;
    return InkWell(
      onTap: fetching ? null : _download,
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: _w,
          height: _h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                widget.inlineThumb!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _iconBox(cs),
              ),
              // Dim the preview so the overlay reads clearly.
              Container(color: Colors.black.withAlpha(fetching ? 110 : 60)),
              if (fetching)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white)),
                      const SizedBox(height: 8),
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700)),
                      Text(sub,
                          style: TextStyle(
                              color: Colors.white.withAlpha(220),
                              fontSize: 10.5)),
                    ],
                  ),
                )
              else
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(140),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(isClip ? Icons.play_arrow : Icons.download,
                            size: 18, color: Colors.white),
                        const SizedBox(width: 6),
                        Text(isClip ? 'Play' : 'Download',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              // Size badge.
              if (_sizeLabel != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(150),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_sizeLabel!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final archive = sharedMediaArchive();
    final meta = archive?.getMeta(ref.sha256);

    // Not in the local archive yet. If the post embedded a tiny preview (`tn:`),
    // ALWAYS show it as a real thumbnail (with a download overlay / progress) so
    // media posts have a picture even before the full file is fetched.
    if (archive == null || meta == null) {
      if (widget.inlineThumb != null) return _inlinePreview(cs);
      if (_poll?.isActive ?? false) return _lookingChip(cs);
      if ((_tooLargeForAuto || widget.tapOnly) && !_requested) {
        return _downloadChip(cs);
      }
      return _notAvailableChip(cs);
    }

    // Tapped a video/audio clip: play it EMBEDDED right here in the stream
    // (a headless decoder feeds the codec-free sink), with a fullscreen
    // button. The bytes must be local (they are — the thumbnail showed).
    if (_playing &&
        (ref.kind == MediaKind.video || ref.kind == MediaKind.audio)) {
      final bytes = archive.get(ref.sha256);
      if (bytes != null) {
        final isAudio = ref.kind == MediaKind.audio;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: _w,
            height: isAudio ? 72 : _h, // audio: a compact control bar
            child: WasmVideoPlayer(
              mediaBytes: bytes,
              ext: ref.ext,
              fit: BoxFit.contain,
              isAudio: isAudio,
              title: meta.name,
            ),
          ),
        );
      }
      _playing = false; // bytes vanished — fall back to the thumbnail
    }

    // Preview bytes: the stored screenshot wins; otherwise images decode their
    // own (small) data directly. Read ONCE and cache (see [_preview]).
    _preview ??= archive.getScreenshot(ref.sha256) ??
        (ref.kind == MediaKind.image ? archive.get(ref.sha256) : null);
    // Ensure the clip has an attractive poster (generates once, persisted +
    // reused; upgrades old first-frame posters). Self-guards against repeats.
    if (ref.kind == MediaKind.video) {
      unawaited(_ensureVideoThumb(archive));
    }
    final preview = _preview;

    final Widget inner;
    if (preview != null) {
      inner = Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            preview,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: (_w * 2).toInt(),
            errorBuilder: (_, __, ___) => _iconBox(cs),
          ),
          // Tappable play button: starts playback INLINE in the stream
          // (no navigation). It's an interactive Material on top of the
          // thumbnail, so its tap wins over the enclosing post's
          // open-thread InkWell.
          if (ref.kind == MediaKind.video || ref.kind == MediaKind.audio)
            Center(child: _playButton()),
          // Size badge (from the wire hint or the stored size).
          if (_sizeLabel != null || meta.size > 0)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(150),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _sizeLabel ?? formatBytes(meta.size),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      );
    } else if (ref.kind == MediaKind.video || ref.kind == MediaKind.audio) {
      inner = Stack(
        fit: StackFit.expand,
        children: [
          _iconBox(cs,
              icon: ref.kind == MediaKind.audio
                  ? Icons.audiotrack
                  : Icons.movie_outlined),
          Center(child: _playButton()),
        ],
      );
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

    final isVideo =
        ref.kind == MediaKind.video || ref.kind == MediaKind.audio;
    return InkWell(
      onTap: () {
        if (isVideo) {
          setState(() => _playing = true); // play embedded in the stream
        } else {
          MediaViewerPage.open(context, ref);
        }
      },
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

  /// A tappable play button overlaid on a video/audio thumbnail. Tapping it
  /// starts playback INLINE in the stream (sets [_playing]); being an
  /// interactive Material on top, its tap wins over the post's open-thread tap.
  Widget _playButton() => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() => _playing = true),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(Icons.play_arrow, color: Colors.white, size: 34),
          ),
        ),
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
  MediaRef get _ref => widget.mediaRef;

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
        final data = archive.get(_ref.sha256);
        if (data == null) {
          return _fallback(Icons.broken_image, 'Media data missing.');
        }
        // Full-size playback: the decoder runs in the player wapp (wasm),
        // rendering through the host's codec-free A/V sink.
        final isAudio = _ref.kind == MediaKind.audio;
        return Center(
          child: SizedBox(
            width: double.infinity,
            height: isAudio ? 96 : double.infinity,
            child: WasmVideoPlayer(
                mediaBytes: data,
                ext: _ref.ext,
                fit: BoxFit.contain,
                allowFullscreen: false,
                isAudio: isAudio,
                title: meta.name),
          ),
        );
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
