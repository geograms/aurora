/// NIP-92 `imeta` tags: per-URL media metadata a NOSTR post carries for its
/// attachments — ["imeta", "url https://…mp4", "m video/mp4", "dim 1080x1920",
/// "duration 38.6", "image https://…jpg", "blurhash L6Pj0^…"]. The poster
/// image / blurhash / dimensions let the feed show a real video thumbnail
/// WITHOUT downloading any of the video.
library;

import 'dart:convert';

/// Extract per-URL metadata from an event's tags. Returns url → fields, with
/// only the fields the feed renders (`image`, `blurhash`, `dim`, `dur`).
Map<String, Map<String, String>> imetaFromTags(List<dynamic> tags) {
  final out = <String, Map<String, String>>{};
  for (final t in tags) {
    if (t is! List || t.isEmpty || t.first != 'imeta') continue;
    String? url;
    final fields = <String, String>{};
    for (final entry in t.skip(1)) {
      final s = entry.toString();
      final sp = s.indexOf(' ');
      if (sp <= 0) continue;
      final key = s.substring(0, sp);
      final value = s.substring(sp + 1).trim();
      if (value.isEmpty) continue;
      switch (key) {
        case 'url':
          url = value;
        case 'image':
          fields['image'] = value;
        case 'blurhash':
          fields['blurhash'] = value;
        case 'dim':
          fields['dim'] = value;
        case 'duration':
          fields['dur'] = value;
      }
    }
    if (url != null && fields.isNotEmpty) out[url] = fields;
  }
  return out;
}

/// The activity item's `meta` payload for an event's tags: a compact JSON
/// string `{"imeta":{url:{…}}}`, or '' when the event carries nothing useful.
String imetaMetaJson(List<dynamic> tags) {
  final m = imetaFromTags(tags);
  if (m.isEmpty) return '';
  return jsonEncode({'imeta': m});
}

/// Parse an activity item's `meta` back into url → fields ({} when absent or
/// not imeta-shaped — `meta` is a shared free-form column).
Map<String, Map<String, String>> imetaFromMeta(String? meta) {
  if (meta == null || meta.isEmpty) return const {};
  try {
    final j = jsonDecode(meta);
    final im = (j as Map)['imeta'];
    if (im is! Map) return const {};
    return {
      for (final e in im.entries)
        if (e.value is Map)
          e.key.toString(): {
            for (final f in (e.value as Map).entries)
              f.key.toString(): f.value.toString(),
          },
    };
  } catch (_) {
    return const {};
  }
}
