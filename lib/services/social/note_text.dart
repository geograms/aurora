import '../../util/nostr_nip19.dart';

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

// ── Mentions (NIP-19) ───────────────────────────────────────────────────────
//
// A mention is a person, and 63 characters of bech32 is not a person. Every
// place a note is shown — the feed, a profile bio, the launcher hero — must be
// able to turn `nostr:npub1mxq4j…` into `@Alice`.
//
// The `nostr:` prefix is OPTIONAL. Requiring it (which the old feed-only regex
// did) meant a bare `npub1…`, which is what most clients actually write, was
// matched by nothing at all — and that is why the hero was showing raw bech32.

/// `nostr:`-prefixed or bare NIP-19 token.
///
/// The lookbehind keeps it out of URLs and out of the middle of words: a bech32
/// string can and does appear inside a link (`https://njump.me/npub1…`), and
/// re-labelling half of somebody's URL is worse than not decoding at all.
final RegExp noteMentionRe = RegExp(
  r'(?<![\w/:.@])(?:nostr:)?'
  r'((?:npub1|nprofile1|nevent1|note1|naddr1)'
  r'[023456789acdefghjklmnpqrstuvwxyz]{20,})',
  caseSensitive: false,
);

/// One decoded mention and where it sits in the text.
///
/// The KEY is kept, not just a label. Throwing it away after substitution is
/// what made a mention un-tappable: by the time the string reached a widget,
/// there was nothing left to open a profile with.
class NoteMention {
  final int start;
  final int end;
  final String type; // npub | nprofile | nevent | note | naddr
  final String token; // the bech32, without the nostr: prefix
  final String? pubkeyHex; // npub / nprofile / naddr
  final String? eventIdHex; // note / nevent

  const NoteMention({
    required this.start,
    required this.end,
    required this.type,
    required this.token,
    this.pubkeyHex,
    this.eventIdHex,
  });

  /// A mention of a PERSON — the only kind that can open a profile.
  bool get isPerson => pubkeyHex != null && pubkeyHex!.length == 64;
}

/// Every NIP-19 token in [text], in order. Undecodable tokens are skipped —
/// a bech32 string we cannot read is not a mention, it is just text.
List<NoteMention> parseNoteMentions(String text) {
  if (!text.contains('1')) return const []; // every hrp is followed by '1'
  final out = <NoteMention>[];
  for (final m in noteMentionRe.allMatches(text)) {
    final token = m.group(1)!;
    final res = NostrNip19.decode(token);
    if (res == null) continue;
    out.add(NoteMention(
      start: m.start,
      end: m.end,
      type: res.type,
      token: token,
      pubkeyHex: res.pubkeyHex,
      eventIdHex: res.eventIdHex,
    ));
  }
  return out;
}

/// What a mention READS as. [name] is the resolved display name, or null while
/// the author's kind-0 has not arrived yet (or never does).
///
/// An unresolved person still gets a short, stable handle rather than the full
/// key: the point is that a human can read the line.
String mentionLabel(NoteMention m, String? name) {
  if (!m.isPerson) return '↗ note';
  if (name != null && name.trim().isNotEmpty) return '@${name.trim()}';
  final t = m.token;
  return '@${t.substring(0, t.length < 12 ? t.length : 12)}…';
}

/// The plain-string form, for callers that render a `String` and cannot carry a
/// tap target (the launcher hero). [resolve] is given the bech32 token.
String formatNoteMentions(
    String text, String? Function(String token)? resolve) {
  final mentions = parseNoteMentions(text);
  if (mentions.isEmpty) return text;
  final b = StringBuffer();
  var i = 0;
  for (final m in mentions) {
    if (m.start > i) b.write(text.substring(i, m.start));
    b.write(mentionLabel(m, m.isPerson ? resolve?.call(m.token) : null));
    i = m.end;
  }
  if (i < text.length) b.write(text.substring(i));
  return b.toString();
}
