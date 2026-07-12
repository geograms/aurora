import 'dart:typed_data';

/// One card on the launcher's hero carousel.
///
/// Deliberately source-agnostic: a NOSTR post, a blog entry published by a wapp,
/// or anything else a wapp wants to surface all arrive here as the same shape.
/// The launcher never asks where an item came from except to route a tap.
class HeroItem {
  /// Globally unique: `<sourceId>:<the source's own id>`. Two sources can hand
  /// us the same raw id without colliding, and dedup is a set of strings.
  final String id;

  /// `nostr` for the built-in source, else the publishing wapp's id.
  final String sourceId;

  /// Which wapp a tap opens, resolved through the launcher's `provides.intents`.
  final String? intent;

  final String title;
  final String summary;

  /// `http(s)://…` or a `file:<sha256>.<ext>` MediaArchive token. Items whose
  /// media we have mirrored locally carry the token, and render from disk.
  final String? imageUrl;

  /// Inline preview bytes (a NOSTR `tn:` token), shown while [imageUrl] loads
  /// and kept as the backdrop when there is no image at all.
  final Uint8List? thumbnail;

  /// When the thing happened — what the "19 minutes ago" label reads, and what
  /// the ranker decays against. Not when we heard about it.
  final DateTime createdAt;

  /// Wapp-published items expire; NOSTR items don't (the buffer bounds them).
  final DateTime? expiresAt;

  final String? authorPubkey;
  final String authorName;
  final String? authorPic;

  /// Engagement, for the ranker. Wapp items have none and score as 1.
  final int likes;
  final int replies;

  /// Publisher's own importance hint, clamped 0..2 on the way in. It can nudge
  /// an item up; it can never let one wapp own the carousel (see hero_ranker).
  final int priority;

  /// Handed to the wapp as `initialView` on tap (`post:<id>`, `entry:42`, …).
  final String? deepLink;

  /// Handed to the wapp as `initialPost` — lets it render without re-fetching.
  final Map<String, dynamic>? payload;

  const HeroItem({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.summary,
    required this.createdAt,
    required this.authorName,
    this.intent,
    this.imageUrl,
    this.thumbnail,
    this.expiresAt,
    this.authorPubkey,
    this.authorPic,
    this.likes = 0,
    this.replies = 0,
    this.priority = 0,
    this.deepLink,
    this.payload,
  });

  bool get hasImage => imageUrl != null || thumbnail != null;

  bool get isNostr => sourceId == kHeroSourceNostr;

  bool expired(DateTime now) =>
      expiresAt != null && now.isAfter(expiresAt!);

  /// Cheap identity for the "did the feed actually change" check — the carousel
  /// must not rebuild mid-swipe for a like count that didn't move.
  String get signature => '$id/$likes/$replies/$authorName/$imageUrl';

  HeroItem copyWith({
    String? authorName,
    String? authorPic,
    String? imageUrl,
    int? likes,
    int? replies,
  }) =>
      HeroItem(
        id: id,
        sourceId: sourceId,
        intent: intent,
        title: title,
        summary: summary,
        imageUrl: imageUrl ?? this.imageUrl,
        thumbnail: thumbnail,
        createdAt: createdAt,
        expiresAt: expiresAt,
        authorPubkey: authorPubkey,
        authorName: authorName ?? this.authorName,
        authorPic: authorPic ?? this.authorPic,
        likes: likes ?? this.likes,
        replies: replies ?? this.replies,
        priority: priority,
        deepLink: deepLink,
        payload: payload,
      );
}

const String kHeroSourceNostr = 'nostr';
