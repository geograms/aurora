final RegExp _noteFileRe = RegExp(r'file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}');
final RegExp _noteHttpMediaRe = RegExp(
  r'https?://[^\s]+?\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|mov|webm|m4v)(?:\?[^\s]*)?',
  caseSensitive: false,
);
final RegExp _noteThumbnailRe = RegExp(r'\btn:[A-Za-z0-9_-]+=*');
final RegExp _noteInfoHashRe = RegExp(r'\bih:[0-9a-fA-F]{40}\b');
final RegExp _noteSizeRe = RegExp(r'\bsz:\d+\b');

final RegExp _noteHttpImageRe = RegExp(
  r'https?://[^\s]+?\.(?:jpg|jpeg|png|gif|webp)(?:\?[^\s]*)?',
  caseSensitive: false,
);

/// First inline http(s) IMAGE url in a note, or null. Video/audio urls are
/// deliberately excluded — callers use this for still backgrounds.
String? firstNoteImageUrl(String s) => _noteHttpImageRe.firstMatch(s)?.group(0);

/// Every inline http(s) IMAGE url in a note, in order, deduped. Bounded: a note
/// is free to carry twenty pictures, but we only ever mirror a handful of them.
List<String> allNoteImageUrls(String s, {int max = 4}) {
  final out = <String>[];
  for (final m in _noteHttpImageRe.allMatches(s)) {
    final url = m.group(0)!;
    if (out.contains(url)) continue;
    out.add(url);
    if (out.length == max) break;
  }
  return out;
}

String stripNoteTokens(String s) => s
    .replaceAll(_noteFileRe, '')
    .replaceAll(_noteHttpMediaRe, '')
    .replaceAll(_noteThumbnailRe, '')
    .replaceAll(_noteInfoHashRe, '')
    .replaceAll(_noteSizeRe, '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
