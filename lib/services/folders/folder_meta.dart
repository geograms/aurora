/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * `data/meta.json` — what a shared folder SAYS ABOUT ITSELF.
 *
 * A torrent used to be a bare list of files: you could not tell a film from a
 * game from a book without downloading it, and there was nothing to look at.
 * This is the listing — a title, a description, one category, a few tags, and
 * artwork — and it lives INSIDE the shared folder, as ordinary files:
 *
 *   data/meta.json      the authored truth (this file)
 *   data/cover.jpg      poster / box art
 *   data/banner.jpg     wide header
 *   data/trailer.webm   optional clip
 *   data/media1.png     gallery, 1..10, in order (an item may be a short clip)
 *
 * Two consequences, and they are the whole point:
 *
 *   * it TRAVELS with the content. `data/` is scanned, hashed, published and
 *     re-seeded like any other file, so the description can never be separated
 *     from the thing it describes;
 *   * a HUMAN can write it. Drop a meta.json and a cover.jpg in with a file
 *     manager, rescan, and the listing appears. That is what "it is just a
 *     folder" buys, and it is why this — not the signed op-log — is the thing a
 *     person edits. The op-log is a MIRROR of this file (disk_folder_manager
 *     emits setMeta to match it), so a stranger can read the title and filter by
 *     category without downloading a single byte.
 *
 * The directory must be `data/`, NOT `.data/`: the scanner skips every path
 * segment starting with '.' (that is how the master key `.folder.json` stays
 * unshared), so a dot-prefixed directory would never be published at all.
 *
 * Everything here treats the file as UNTRUSTED INPUT — it arrives from a
 * stranger's folder. Parsing clamps every limit and never throws.
 */

import 'dart:convert';

import 'package:reticulum/reticulum.dart' show MediaKind, MediaRef;

/// The directory (inside the shared folder) that carries the listing.
const String kFolderDataDir = 'data';

/// The listing file itself.
const String kFolderMetaFile = 'meta.json';

/// What a folder holds, one value, mandatory. Modelled on what torrent sites
/// actually list — the buckets people genuinely filter on (a series is not a
/// film; an audiobook is not music; a manga is not a comic).
const List<String> kFolderCategories = [
  'film',
  'series',
  'anime',
  'documentary',
  'music',
  'audiobook',
  'book',
  'comic',
  'manga',
  'magazine',
  'game',
  'software',
  'course',
  'podcast',
  'photo',
  'dataset',
  'other',
];

const String kFolderCategoryFallback = 'other';

const int kMetaTitleMax = 50;
const int kMetaDescMax = 200;
const int kMetaTagsMax = 10;
const int kMetaTagLenMax = 24;
const int kMetaGalleryMax = 10;

/// Per-media size ceiling. `data/` is what a browsing client pulls BEFORE it
/// decides to download the torrent, so each piece of artwork has to stay cheap.
const int kMetaMediaMaxBytes = 30 * 1024 * 1024;

/// The listing of one shared folder.
class FolderMeta {
  final String title; // ≤ kMetaTitleMax
  final String desc; // ≤ kMetaDescMax
  final String cat; // exactly one of kFolderCategories
  final List<String> tags; // ≤ kMetaTagsMax
  final bool adult; // +18. A FLAG, not a category: an adult film is still a film

  /// File names relative to `data/` (never a path — see [_safeName]).
  final String? cover;
  final String? banner;
  final String? trailer;
  final List<String> gallery; // ≤ kMetaGalleryMax, ordered

  /// Keys we did not recognise, kept so that a NEWER publisher's field is not
  /// destroyed when an older client rewrites the file.
  final Map<String, dynamic> extra;

  const FolderMeta({
    this.title = '',
    this.desc = '',
    this.cat = kFolderCategoryFallback,
    this.tags = const [],
    this.adult = false,
    this.cover,
    this.banner,
    this.trailer,
    this.gallery = const [],
    this.extra = const {},
  });

  bool get isEmpty =>
      title.isEmpty &&
      desc.isEmpty &&
      tags.isEmpty &&
      cover == null &&
      banner == null &&
      trailer == null &&
      gallery.isEmpty;

  /// Every media file this listing references, in `data/<name>` form — what the
  /// gallery needs to resolve, and what the size cap applies to.
  List<String> get mediaNames => [
        if (cover != null) cover!,
        if (banner != null) banner!,
        if (trailer != null) trailer!,
        ...gallery,
      ];

  /// Parse a `data/meta.json`. NEVER throws: a folder from a stranger can hold
  /// anything at all, and the right answer to garbage is a clamped listing (or
  /// an empty one), not a crash in the middle of a folder sync.
  static FolderMeta parse(String jsonText) {
    Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return const FolderMeta();
      m = decoded.cast<String, dynamic>();
    } catch (_) {
      return const FolderMeta();
    }

    const known = {
      'title',
      'desc',
      'cat',
      'tags',
      'adult',
      'cover',
      'banner',
      'trailer',
      'gallery',
    };

    return FolderMeta(
      title: _clamp('${m['title'] ?? ''}', kMetaTitleMax),
      desc: _clamp('${m['desc'] ?? ''}', kMetaDescMax),
      cat: _category('${m['cat'] ?? ''}'),
      tags: _tags(m['tags']),
      adult: m['adult'] == true,
      cover: _mediaName(m['cover'], want: MediaKind.image),
      banner: _mediaName(m['banner'], want: MediaKind.image),
      trailer: _mediaName(m['trailer'], want: MediaKind.video),
      gallery: _gallery(m['gallery']),
      extra: {
        for (final e in m.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        ...extra, // first, so a recognised key always wins over a stale unknown
        'title': title,
        'desc': desc,
        'cat': cat,
        'tags': tags,
        if (adult) 'adult': true,
        if (cover != null) 'cover': cover,
        if (banner != null) 'banner': banner,
        if (trailer != null) 'trailer': trailer,
        if (gallery.isNotEmpty) 'gallery': gallery,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  FolderMeta copyWith({
    String? title,
    String? desc,
    String? cat,
    List<String>? tags,
    bool? adult,
    String? cover,
    String? banner,
    String? trailer,
    List<String>? gallery,
  }) =>
      FolderMeta(
        title: _clamp(title ?? this.title, kMetaTitleMax),
        desc: _clamp(desc ?? this.desc, kMetaDescMax),
        cat: _category(cat ?? this.cat),
        tags: _tags(tags ?? this.tags),
        adult: adult ?? this.adult,
        cover: cover ?? this.cover,
        banner: banner ?? this.banner,
        trailer: trailer ?? this.trailer,
        gallery: (gallery ?? this.gallery).take(kMetaGalleryMax).toList(),
        extra: extra,
      );

  /// The comma-separated form the signed op-log carries (`setMeta.tags` has
  /// always been one string, and the `files` wapp reads it that way).
  String get tagsWire => tags.join(', ');

  static List<String> tagsFromWire(String s) => _tags(s);

  // ── the clamps ────────────────────────────────────────────────────────────

  static String _clamp(String s, int max) {
    final t = s.trim();
    return t.length <= max ? t : t.substring(0, max);
  }

  static String _category(String s) {
    final c = s.trim().toLowerCase();
    return kFolderCategories.contains(c) ? c : kFolderCategoryFallback;
  }

  static List<String> _tags(Object? raw) {
    final parts = <String>[];
    if (raw is List) {
      parts.addAll(raw.map((e) => '$e'));
    } else if (raw is String) {
      parts.addAll(raw.split(RegExp(r'[,\s]+')));
    }
    final out = <String>[];
    for (final p in parts) {
      final t = _clamp(p, kMetaTagLenMax);
      if (t.isEmpty) continue;
      if (out.contains(t)) continue;
      out.add(t);
      if (out.length >= kMetaTagsMax) break;
    }
    return out;
  }

  static List<String> _gallery(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      final n = _mediaName(e, want: null);
      if (n == null) continue;
      if (out.contains(n)) continue;
      out.add(n);
      if (out.length >= kMetaGalleryMax) break;
    }
    return out;
  }

  /// A media reference is a BARE FILE NAME inside `data/` — never a path.
  ///
  /// This is the security boundary of the whole feature: the name comes from a
  /// stranger's JSON and is about to be joined onto a real directory, so
  /// anything that could climb out of it ("../../.folder.json", an absolute
  /// path, a nested directory) is refused outright rather than sanitised into
  /// something that merely looks safe.
  static String? _mediaName(Object? raw, {MediaKind? want}) {
    if (raw is! String) return null;
    final n = raw.trim();
    if (n.isEmpty || n.length > 64) return null;
    if (n.contains('/') || n.contains('\\')) return null;
    if (n.contains('..') || n.startsWith('.')) return null;
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(n)) return null;

    final dot = n.lastIndexOf('.');
    if (dot <= 0 || dot == n.length - 1) return null;
    final kind = MediaRef.classify(n.substring(dot + 1).toLowerCase());
    if (kind != MediaKind.image && kind != MediaKind.video) return null;
    if (want != null && kind != want) return null;
    return n;
  }
}
