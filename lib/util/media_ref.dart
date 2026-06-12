// APRX media reference tokens (APRX.md §16).
//
// A file embedded in a plain APRS text message is referenced by content, not
// by transport: the sender includes the token
//
//   file:<sha256-base64url>.<ext>
//
// where <sha256-base64url> is the unpadded base64url encoding of the file's
// SHA-256 (exactly 43 chars) and <ext> is the original file extension
// (lowercase, 1–18 alphanumerics). The extension lets a receiver decide how
// the reference could be displayed (image / video / audio / plain file)
// before it has the bytes. How the bytes are obtained is out of scope here —
// this util only recognises and classifies the token.
//
// Pure Dart (no Flutter, no I/O) so it is trivially unit-testable.

import 'dart:convert';
import 'dart:typed_data';

/// How a media reference could be presented, judged by its extension alone.
enum MediaKind { image, video, audio, file }

class MediaRef {
  /// Unpadded base64url SHA-256 of the file bytes (43 chars).
  final String sha256;

  /// Lowercase extension without the dot (1–18 alphanumerics).
  final String ext;

  /// Display classification derived from [ext].
  final MediaKind kind;

  const MediaRef({required this.sha256, required this.ext, required this.kind});

  /// The wire token, e.g. `file:qL0g…X9w.png`.
  String get token => 'file:$sha256.$ext';

  // 5 ("file:") + 43 (hash) + 1 (".") + 18 (max ext) = 67 chars — the APRS
  // message line limit, so a token always survives multi-line word-splitting
  // (APRX.md §5) intact on a single line.
  static final RegExp _tokenRe =
      RegExp(r'file:([A-Za-z0-9_-]{43})\.([a-z0-9]{1,18})');

  /// Parse one exact token string; null if [s] is not a valid token.
  static MediaRef? parse(String s) {
    final m = _tokenRe.matchAsPrefix(s);
    if (m == null || m.end != s.length) return null;
    final ext = m.group(2)!;
    return MediaRef(sha256: m.group(1)!, ext: ext, kind: classify(ext));
  }

  /// Extract every media token from a free-text message body. Tokens carry no
  /// punctuation characters, so an adjacent sentence period / comma / bracket
  /// naturally falls outside the match.
  static List<MediaRef> findAll(String text) => [
        for (final m in _tokenRe.allMatches(text))
          MediaRef(
            sha256: m.group(1)!,
            ext: m.group(2)!,
            kind: classify(m.group(2)!),
          ),
      ];

  /// Classify a (lowercase) extension. Unknown extensions are a generic
  /// [MediaKind.file] attachment.
  static MediaKind classify(String ext) =>
      _kinds[ext.toLowerCase()] ?? MediaKind.file;

  // ── digest encodings ────────────────────────────────────────────────────
  // One SHA-256, two wire forms: APRX tokens use unpadded base64url (43
  // chars); Blossom URLs / NOSTR events use lowercase hex (64 chars).

  /// The token hash as lowercase hex (e.g. for a Blossom `GET /<sha256>`).
  String get sha256Hex => b64uToHex(sha256)!;

  /// base64url(43) → lowercase hex(64); null if [s] is not a valid digest.
  static String? b64uToHex(String s) {
    try {
      final pad = (4 - s.length % 4) % 4;
      final bytes = base64Url.decode(s + ('=' * pad));
      if (bytes.length != 32) return null;
      final sb = StringBuffer();
      for (final b in bytes) {
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    } catch (_) {
      return null;
    }
  }

  /// lowercase/uppercase hex(64) → unpadded base64url(43); null if invalid.
  static String? hexToB64u(String hex) {
    if (hex.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
      return null;
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // Keep in sync with the table in APRX.md §16.3. gif is classified as video
  // (animated playback), matching the protocol spec.
  static const Map<String, MediaKind> _kinds = {
    // image
    'png': MediaKind.image,
    'jpg': MediaKind.image,
    'jpeg': MediaKind.image,
    'webp': MediaKind.image,
    'bmp': MediaKind.image,
    'svg': MediaKind.image,
    'avif': MediaKind.image,
    'heic': MediaKind.image,
    'tif': MediaKind.image,
    'tiff': MediaKind.image,
    'ico': MediaKind.image,
    // video (gif rides here: it is shown as a looping clip)
    'gif': MediaKind.video,
    'webm': MediaKind.video,
    'mpeg': MediaKind.video,
    'mpg': MediaKind.video,
    'mp4': MediaKind.video,
    'mov': MediaKind.video,
    'avi': MediaKind.video,
    'mkv': MediaKind.video,
    'ogv': MediaKind.video,
    // audio
    'mp3': MediaKind.audio,
    'ogg': MediaKind.audio,
    'aac': MediaKind.audio,
    'flac': MediaKind.audio,
    'wav': MediaKind.audio,
    'opus': MediaKind.audio,
  };
}
