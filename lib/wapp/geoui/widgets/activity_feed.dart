// Twitter/X-style Activity feed: a compose box pinned at the TOP ("What's
// happening?"), then a centered, single-column stream of posts as cards (avatar,
// callsign, time, origin chip, text, image/video thumbnails). Tapping a post
// opens its conversation; tapping a name opens the profile. App-agnostic — it
// just renders the post maps it's given and reports compose/attach/taps back.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../../util/media_ref.dart';
import '../../shared_media_fetch.dart' show mediaSizeHint;
import 'chat_palette.dart';
import 'chat_view_field.dart' show viaTagColor;
import 'generated_avatar.dart';
import 'media_view.dart';

class ActivityFeed extends StatefulWidget {
  /// Posts oldest→newest. Each: {from, text, time, via?, convo?, kind?}.
  final List<Map<String, dynamic>> posts;
  final ValueChanged<String> onSend;
  final Future<String?> Function()? onAttach;
  final void Function(Map<String, dynamic> post)? onItemTap;
  final void Function(String from)? onSenderTap;
  /// Optional identity lookup: callsign -> short npub (or other detail) shown
  /// under the name on each post. Null = show callsign only.
  final String? Function(String callsign)? npubFor;

  // ── Social actions (Like / Reply / Save) ──────────────────────────────────
  /// Like count + whether we liked, for a post id (mid).
  final ({int count, bool mine}) Function(String mid)? likeInfo;
  final bool Function(String mid)? isSaved;
  final void Function(String mid, bool like)? onLike;
  final void Function(Map<String, dynamic> post)? onSave;
  /// Bookmarked posts, newest-first, for the Favorites tab.
  final List<Map<String, dynamic>> Function()? savedPosts;

  /// Tapping our own avatar (the composer's "me" image) opens our profile.
  final VoidCallback? onSelfTap;
  /// Our own avatar image for the composer, if set.
  final ImageProvider? selfAvatar;

  /// Resolve a post author's callsign to its display name + avatar (from its
  /// NOSTR profile). Null/absent fields fall back to callsign + initials.
  final ({String? name, ImageProvider? avatar}) Function(String callsign)?
      profileFor;

  /// Number of replies to a post id, shown on each post in the feed.
  final int Function(String mid)? replyCount;

  /// Open a publication's full-screen forum thread (replies). The host pushes
  /// the thread page.
  final void Function(Map<String, dynamic> post)? onOpenThread;

  /// Callsigns we follow (for the Following filter).
  final Set<String> followedCalls;

  /// Callsigns to hide from the feed (blocked + muted), pushed by the wapp.
  final Set<String> hiddenCalls;

  /// Block / mute a callsign from a post's "…" menu.
  final void Function(String from)? onBlock;
  final void Function(String from)? onMute;

  final String hint;

  const ActivityFeed({
    super.key,
    required this.posts,
    required this.onSend,
    this.onAttach,
    this.onItemTap,
    this.onSenderTap,
    this.npubFor,
    this.likeInfo,
    this.isSaved,
    this.onLike,
    this.onSave,
    this.savedPosts,
    this.onSelfTap,
    this.selfAvatar,
    this.profileFor,
    this.replyCount,
    this.onOpenThread,
    this.followedCalls = const {},
    this.hiddenCalls = const {},
    this.onBlock,
    this.onMute,
    this.hint = "What's happening?",
  });

  @override
  State<ActivityFeed> createState() => _ActivityFeedState();
}

/// Activity feed view filter: everything, only people we follow, or the posts
/// we've bookmarked.
enum _ActivityFilter { all, following, favorites }

class _ActivityFeedState extends State<ActivityFeed> {
  final _input = TextEditingController();
  final _pending = <({String token, MediaRef ref})>[];
  _ActivityFilter _filter = _ActivityFilter.all;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _post() {
    var text = _input.text.trim();
    if (_pending.isNotEmpty) {
      final tokens = _pending.map((p) => p.token).join(' ');
      text = text.isEmpty ? tokens : '$text $tokens';
    }
    if (text.isEmpty) return;
    widget.onSend(text);
    _input.clear();
    _pending.clear();
    setState(() {});
  }

  Future<void> _attach() async {
    final token = await widget.onAttach!();
    if (token == null || token.isEmpty) return;
    final refs = MediaRef.findAll(token);
    if (refs.isNotEmpty) _pending.add((token: token, ref: refs.first));
    if (mounted) setState(() {});
  }

  /// The Activity tab is the micro-blog stream only: genuine stream posts (FEED
  /// + status) carry an empty `convo`, while group/DM messages that older builds
  /// mirrored in carry the group/callsign there. Drop the latter so historical
  /// group chatter disappears from the stream too (new builds no longer mirror).
  bool _isStreamPost(Map<String, dynamic> p) =>
      (p['convo'] ?? '').toString().trim().isEmpty;

  /// A root publication (not a reply) — replies live inside their thread, not in
  /// the top-level stream.
  bool _isRoot(Map<String, dynamic> p) =>
      (p['parent'] ?? '').toString().trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Newest first (Twitter order), filtered by the All/Following/Favorites tab.
    List<Map<String, dynamic>> posts;
    switch (_filter) {
      case _ActivityFilter.favorites:
        // Bookmarked posts come from the saved store, already newest-first.
        posts = widget.savedPosts?.call() ?? const [];
        break;
      case _ActivityFilter.following:
        posts = widget.posts.reversed.where((p) {
          if (!_isStreamPost(p) || !_isRoot(p)) return false;
          final from = (p['from'] ?? '').toString().toUpperCase();
          final out = (p['dir'] ?? '') == 'out';
          return out || widget.followedCalls.contains(from);
        }).toList();
        break;
      case _ActivityFilter.all:
        posts = widget.posts.reversed
            .where((p) => _isStreamPost(p) && _isRoot(p))
            .toList();
        break;
    }
    // Hide posts from blocked/muted callsigns (the wapp pushes the set).
    if (widget.hiddenCalls.isNotEmpty) {
      posts = posts
          .where((p) =>
              !widget.hiddenCalls.contains((p['from'] ?? '').toString().toUpperCase()))
          .toList();
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          children: [
            // Filter sits right below the nav tabs (Activity/Messages/…), with
            // the composer card underneath it (its own tinted box + margins set
            // it apart from the stream — no extra dividers needed).
            _filterBar(cs),
            Divider(height: 1, color: cs.outlineVariant.withAlpha(45)),
            _composer(cs),
            Expanded(
              child: posts.isEmpty
                  ? _empty(cs)
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: posts.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1, color: cs.outlineVariant.withAlpha(45)),
                      itemBuilder: (_, i) => ActivityPostCard(
                        post: posts[i],
                        profileFor: widget.profileFor,
                        npubFor: widget.npubFor,
                        onSenderTap: widget.onSenderTap,
                        likeInfo: widget.likeInfo,
                        onLike: widget.onLike,
                        isSaved: widget.isSaved,
                        onSave: widget.onSave,
                        replyCount: widget.replyCount,
                        onBlock: widget.onBlock,
                        onMute: widget.onMute,
                        onTap: () => widget.onOpenThread?.call(posts[i]),
                        onReply: () => widget.onOpenThread?.call(posts[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Filter the noise: everything, only people you follow, or your bookmarks.
  Widget _filterBar(ColorScheme cs) {
    Widget tab(IconData icon, String label, _ActivityFilter value) {
      final selected = _filter == value;
      final color = selected ? ChatPalette.accent : ChatPalette.secondary;
      return InkWell(
        onTap: () => setState(() => _filter = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tab(Icons.public, 'All', _ActivityFilter.all),
          tab(Icons.people, 'Following', _ActivityFilter.following),
          tab(Icons.bookmark, 'Saved', _ActivityFilter.favorites),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme cs) {
    final msg = switch (_filter) {
      _ActivityFilter.favorites =>
        'No saved posts yet.\nTap the bookmark on a post to save it here.',
      _ActivityFilter.following =>
        'Nothing from people you follow yet.\nFollow callsigns to see their posts here.',
      _ActivityFilter.all =>
        'No activity yet.\nPosts from groups and people you follow show here.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(msg,
            textAlign: TextAlign.center,
            style: const TextStyle(color: ChatPalette.secondary, fontSize: 13)),
      ),
    );
  }

  // ── Composer (top) ──────────────────────────────────────────────────────
  // A distinct, slightly-tinted card so it's clearly a place to write a status,
  // set apart from the stream of others' posts below.
  Widget _composer(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: ChatPalette.inBubble,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ChatPalette.accent.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.onSelfTap,
                child: _avatar('', cs, me: true),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _input,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle:
                        TextStyle(color: Colors.white.withAlpha(110), fontSize: 16),
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
          if (_pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 50, top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _pending.length; i++)
                    _attachChip(cs, _pending[i].ref, i),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                if (widget.onAttach != null)
                  // Sit the attach control under the avatar, flush to the left
                  // edge (a tight 36px box matching the avatar's width so the
                  // icon lines up beneath the profile picture).
                  SizedBox(
                    width: 36,
                    child: IconButton(
                      icon: const Icon(Icons.attach_file),
                      tooltip: 'Attach an image or video',
                      color: ChatPalette.accent,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 36, minHeight: 36),
                      onPressed: _attach,
                    ),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _post,
                  style: FilledButton.styleFrom(
                    backgroundColor: ChatPalette.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  ),
                  child: const Text('Post'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachChip(ColorScheme cs, MediaRef ref, int index) {
    Widget inner;
    if (ref.kind == MediaKind.image) {
      final bytes = sharedMediaArchive()?.get(ref.sha256);
      inner = bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : Container(color: Colors.black26);
    } else {
      inner = Container(
        color: Colors.black54,
        child: Center(
          child: Icon(
              ref.kind == MediaKind.video ? Icons.movie : Icons.insert_drive_file,
              color: Colors.white,
              size: 22),
        ),
      );
    }
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: inner),
        Positioned(
          top: -6,
          right: -6,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            iconSize: 18,
            icon: const Icon(Icons.cancel, color: Colors.white),
            onPressed: () => setState(() => _pending.removeAt(index)),
          ),
        ),
      ]),
    );
  }

  /// The composer's own ("me") avatar.
  Widget _avatar(String call, ColorScheme cs, {bool me = false}) {
    if (widget.selfAvatar != null) {
      return CircleAvatar(radius: 18, backgroundImage: widget.selfAvatar);
    }
    return GeneratedAvatar(seed: call.isNotEmpty ? call : 'me', size: 36);
  }
}

// ── Shared helpers + reusable post card ─────────────────────────────────────

/// Post id, mirroring the APRS wapp's msg_id(): first 2 bytes of
/// sha1("from|text") as 4 lowercase hex chars. Fills `mid` for posts archived
/// before the wapp stamped one.
String activityMid(String from, String text) {
  final d = sha1.convert(utf8.encode('$from|$text')).bytes;
  const hx = '0123456789abcdef';
  return '${hx[d[0] >> 4]}${hx[d[0] & 15]}${hx[d[1] >> 4]}${hx[d[1] & 15]}';
}

const _activityMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// Human label for a post's time. The wapp sends a same-day clock string
/// (`time`, HH:MM[:SS]); for posts from earlier days that alone is ambiguous, so
/// when an absolute epoch (`t`, ms) is present we prefix a date ("yesterday HH:MM",
/// "Jun 26 HH:MM", or "Jun 26 2024 HH:MM" for other years). Today's posts keep the
/// plain clock string. Falls back to `time` if no epoch is available.
String activityTimeLabel(Map<String, dynamic> p) {
  final time = (p['time'] ?? '').toString();
  final t = (p['t'] as num?)?.toInt() ?? 0;
  if (t <= 0) return time; // no absolute time — keep the wapp's clock string
  final dt = DateTime.fromMillisecondsSinceEpoch(t);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  if (!day.isBefore(today)) return time; // today (or future-skew) — clock only
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(dt.hour)}:${two(dt.minute)}';
  if (day == today.subtract(const Duration(days: 1))) return 'yesterday $hm';
  final mon = _activityMonths[dt.month - 1];
  return dt.year == now.year
      ? '$mon ${dt.day} $hm'
      : '$mon ${dt.day} ${dt.year} $hm';
}

final _activityFileRe = RegExp(r'file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}');
// An embedded preview thumbnail: `tn:<base64url-png>` (carries padding `=`).
final _activityTnRe = RegExp(r'\btn:([A-Za-z0-9_-]+=*)');
String activityStrip(String s) => s
    .replaceAll(_activityFileRe, '')
    .replaceAll(_activityTnRe, '')
    .replaceAll(RegExp(r'\bih:[0-9a-fA-F]{40}\b'), '')
    .replaceAll(RegExp(r'\bsz:\d+\b'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Decode the embedded `tn:` preview thumbnail from a post body, or null.
Uint8List? activityInlineThumb(String raw) {
  final m = _activityTnRe.firstMatch(raw);
  if (m == null) return null;
  try {
    return base64Url.decode(m.group(1)!);
  } catch (_) {
    return null;
  }
}

Widget _activityAvatar(String call, {ImageProvider? image, double radius = 18}) {
  if (image != null) return CircleAvatar(radius: radius, backgroundImage: image);
  return GeneratedAvatar(seed: call, size: radius * 2);
}

Widget _activityViaChip(String via) {
  final c = viaTagColor(via);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: c.withAlpha(40),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: c.withAlpha(120), width: 0.6),
    ),
    child: Text(via.toUpperCase(),
        style: TextStyle(color: c, fontSize: 8.5, fontWeight: FontWeight.w700)),
  );
}

/// A single publication / reply rendered as a Twitter-style card: avatar, name,
/// time, body, media, and a Like / Reply (with counter) / Save action row.
/// Reused by the feed AND the forum thread (with [indent] for nesting).
class ActivityPostCard extends StatelessWidget {
  final Map<String, dynamic> post;
  final ({String? name, ImageProvider? avatar}) Function(String callsign)?
      profileFor;
  final String? Function(String callsign)? npubFor;
  final void Function(String from)? onSenderTap;
  final ({int count, bool mine}) Function(String mid)? likeInfo;
  final void Function(String mid, bool like)? onLike;
  final bool Function(String mid)? isSaved;
  final void Function(Map<String, dynamic> post)? onSave;
  final int Function(String mid)? replyCount;

  /// Tapping the card body (open the thread). Null = not tappable.
  final VoidCallback? onTap;

  /// Tapping the reply action. Null hides the reply action.
  final VoidCallback? onReply;

  /// Block / mute the post's author (from a "…" menu). Null hides the menu.
  final void Function(String from)? onBlock;
  final void Function(String from)? onMute;

  /// Left indent for a nested reply, and whether to draw a thread connector.
  final double indent;
  final bool connector;

  const ActivityPostCard({
    super.key,
    required this.post,
    this.profileFor,
    this.npubFor,
    this.onSenderTap,
    this.likeInfo,
    this.onLike,
    this.isSaved,
    this.onSave,
    this.replyCount,
    this.onBlock,
    this.onMute,
    this.onTap,
    this.onReply,
    this.indent = 0,
    this.connector = false,
  });

  /// Per-post "…" menu: mute or block the author (only for others' posts).
  Widget _menu(String from) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 18, color: Colors.white54),
        tooltip: 'Options',
        padding: EdgeInsets.zero,
        onSelected: (v) {
          if (v == 'mute') onMute?.call(from);
          if (v == 'block') onBlock?.call(from);
        },
        itemBuilder: (_) => [
          if (onMute != null)
            PopupMenuItem(
              value: 'mute',
              child: Row(children: [
                const Icon(Icons.notifications_off_outlined, size: 18),
                const SizedBox(width: 10),
                Text('Mute $from'),
              ]),
            ),
          if (onBlock != null)
            PopupMenuItem(
              value: 'block',
              child: Row(children: [
                const Icon(Icons.block, size: 18, color: Colors.red),
                const SizedBox(width: 10),
                Text('Block $from'),
              ]),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = post;
    final from = (p['from'] ?? '').toString();
    final raw = (p['text'] ?? '').toString();
    var mid = (p['mid'] ?? '').toString();
    if (mid.isEmpty && from.isNotEmpty && raw.isNotEmpty) {
      mid = activityMid(from, raw);
      p['mid'] = mid;
    }
    final time = activityTimeLabel(p);
    final via = (p['via'] ?? '').toString();
    final body = activityStrip(raw);
    final refs = MediaRef.findAll(raw);
    final fullNpub = from.isEmpty ? null : npubFor?.call(from);
    final npub = fullNpub == null
        ? null
        : (fullNpub.length > 14 ? '${fullNpub.substring(0, 12)}…' : fullNpub);
    final prof = from.isEmpty ? null : profileFor?.call(from);
    final hasNick = (prof?.name?.trim().isNotEmpty) ?? false;
    final displayName =
        hasNick ? prof!.name!.trim() : (from.isEmpty ? 'unknown' : from);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12 + indent, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (connector)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(width: 2, height: 40, color: cs.outlineVariant),
              ),
            GestureDetector(
              onTap: (onSenderTap != null && from.isNotEmpty)
                  ? () => onSenderTap!(from)
                  : null,
              child: _activityAvatar(from, image: prof?.avatar),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: (onSenderTap != null && from.isNotEmpty)
                              ? () => onSenderTap!(from)
                              : null,
                          child: Text(displayName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14)),
                        ),
                      ),
                      if (hasNick && from.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(from,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white.withAlpha(120),
                                  fontSize: 12)),
                        ),
                      ] else if (npub != null) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(npub,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white.withAlpha(120),
                                  fontSize: 12)),
                        ),
                      ],
                      if (time.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text('· $time',
                            style: TextStyle(
                                color: Colors.white.withAlpha(120),
                                fontSize: 12)),
                      ],
                      if (via.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _activityViaChip(via),
                      ],
                      if (from.isNotEmpty &&
                          (p['dir'] ?? '') != 'out' &&
                          (onBlock != null || onMute != null)) ...[
                        const Spacer(),
                        SizedBox(
                            height: 22, width: 28, child: _menu(from)),
                      ],
                    ],
                  ),
                  if (body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(body,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.3)),
                    ),
                  if (refs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (int i = 0; i < refs.length; i++)
                            MediaThumbnail(
                                key: ValueKey('media-${refs[i].sha256}'),
                                ref: refs[i],
                                size: mediaSizeHint(raw),
                                from: from,
                                tapOnly: true,
                                inlineThumb:
                                    i == 0 ? activityInlineThumb(raw) : null),
                        ],
                      ),
                    ),
                  if (mid.isNotEmpty) _actionRow(cs, mid),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(ColorScheme cs, String mid) {
    final info = likeInfo?.call(mid) ?? (count: 0, mine: false);
    final saved = isSaved?.call(mid) ?? false;
    final replies = replyCount?.call(mid) ?? 0;
    const muted = ChatPalette.secondary;

    Widget action(
        IconData icon, String? label, Color color, VoidCallback? onTap) {
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: color),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(label, style: TextStyle(color: color, fontSize: 12)),
              ],
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          action(
            info.mine ? Icons.favorite : Icons.favorite_border,
            info.count > 0 ? '${info.count}' : null,
            info.mine ? Colors.pink : muted,
            onLike == null ? null : () => onLike!(mid, !info.mine),
          ),
          const SizedBox(width: 18),
          action(Icons.chat_bubble_outline, replies > 0 ? '$replies' : null,
              muted, onReply),
          const SizedBox(width: 18),
          action(
            saved ? Icons.bookmark : Icons.bookmark_border,
            null,
            saved ? ChatPalette.accent : muted,
            onSave == null ? null : () => onSave!(post),
          ),
        ],
      ),
    );
  }
}

// ── Full-screen forum thread ────────────────────────────────────────────────

/// A publication and its replies as a forum / Twitter-style thread: the post on
/// top, replies stacked beneath and indented by nesting depth, each its own
/// card with Like / Reply / Save and a reply counter. Full-screen with a single
/// back button (the AppBar's). Replies post to the publication by default, or to
/// a specific message when you tap its Reply.
class ActivityThreadPage extends StatefulWidget {
  final Map<String, dynamic> root;

  /// All replies in the thread (direct + nested), any order.
  final List<Map<String, dynamic>> Function(String rootMid) loadThread;
  final int Function(String mid)? replyCount;
  final ({int count, bool mine}) Function(String mid)? likeInfo;
  final void Function(String mid, bool like)? onLike;
  final bool Function(String mid)? isSaved;
  final void Function(Map<String, dynamic> post)? onSave;

  /// Post a reply [text] under message [parentMid].
  final void Function(String parentMid, String text) onReply;

  final void Function(String from)? onSenderTap;
  final ({String? name, ImageProvider? avatar}) Function(String callsign)?
      profileFor;
  final String? Function(String callsign)? npubFor;

  /// Attach a file to the reply composer (returns a `file:` token).
  final Future<String?> Function()? onAttach;

  /// Rebuild when the activity archive changes (new replies arrive live).
  final Listenable? revision;

  const ActivityThreadPage({
    super.key,
    required this.root,
    required this.loadThread,
    required this.onReply,
    this.replyCount,
    this.likeInfo,
    this.onLike,
    this.isSaved,
    this.onSave,
    this.onSenderTap,
    this.profileFor,
    this.npubFor,
    this.onAttach,
    this.revision,
  });

  @override
  State<ActivityThreadPage> createState() => _ActivityThreadPageState();
}

class _ActivityThreadPageState extends State<ActivityThreadPage> {
  final _input = TextEditingController();
  final _pending = <({String token, MediaRef ref})>[];
  Map<String, dynamic>? _replyTarget; // null = reply to the publication

  String get _rootMid => (widget.root['mid'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    widget.revision?.addListener(_onRev);
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_onRev);
    _input.dispose();
    super.dispose();
  }

  void _onRev() {
    if (mounted) setState(() {});
  }

  /// Depth-first order (parent immediately followed by its nested replies), each
  /// tagged with its nesting depth for indentation.
  List<({Map<String, dynamic> post, int depth})> _ordered() {
    final replies = widget.loadThread(_rootMid);
    final byParent = <String, List<Map<String, dynamic>>>{};
    for (final r in replies) {
      final par = (r['parent'] ?? '').toString();
      (byParent[par] ??= []).add(r);
    }
    final out = <({Map<String, dynamic> post, int depth})>[
      (post: widget.root, depth: 0)
    ];
    void dfs(String mid, int depth) {
      final kids = [...(byParent[mid] ?? const [])]
        ..sort((a, b) =>
            (a['t'] as int? ?? 0).compareTo(b['t'] as int? ?? 0));
      for (final k in kids) {
        out.add((post: k, depth: depth));
        dfs((k['mid'] ?? '').toString(), depth + 1);
      }
    }

    dfs(_rootMid, 1);
    return out;
  }

  Future<void> _attach() async {
    final token = await widget.onAttach?.call();
    if (token == null || token.isEmpty) return;
    final refs = MediaRef.findAll(token);
    if (refs.isNotEmpty) _pending.add((token: token, ref: refs.first));
    if (mounted) setState(() {});
  }

  void _send() {
    var text = _input.text.trim();
    if (_pending.isNotEmpty) {
      final tokens = _pending.map((p) => p.token).join(' ');
      text = text.isEmpty ? tokens : '$text $tokens';
    }
    if (text.isEmpty) return;
    final target = (_replyTarget?['mid'] ?? _rootMid).toString();
    widget.onReply(target, text);
    _input.clear();
    _pending.clear();
    setState(() => _replyTarget = null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = _ordered();
    return Scaffold(
      backgroundColor: ChatPalette.chatBg,
      appBar: AppBar(
        backgroundColor: ChatPalette.windowBg,
        foregroundColor: ChatPalette.text,
        title: const Text('Thread'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1, color: cs.outlineVariant.withAlpha(45)),
                  itemBuilder: (_, i) {
                    final it = items[i];
                    final depth = it.depth.clamp(0, 6);
                    return ActivityPostCard(
                      post: it.post,
                      profileFor: widget.profileFor,
                      npubFor: widget.npubFor,
                      onSenderTap: widget.onSenderTap,
                      likeInfo: widget.likeInfo,
                      onLike: widget.onLike,
                      isSaved: widget.isSaved,
                      onSave: widget.onSave,
                      replyCount: widget.replyCount,
                      indent: depth * 16.0,
                      connector: depth > 0,
                      onReply: () => setState(() => _replyTarget = it.post),
                    );
                  },
                ),
              ),
              // Clear the Android gesture/navigation bar so the reply box isn't
              // hidden behind it.
              SafeArea(top: false, child: _composer(cs)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(ColorScheme cs) {
    final target = _replyTarget;
    return Container(
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: cs.outlineVariant.withAlpha(80))),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (target != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.reply, size: 14, color: ChatPalette.accent),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Replying to ${(target['from'] ?? '').toString()}: '
                      '${activityStrip((target['text'] ?? '').toString())}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: ChatPalette.secondary, fontSize: 12),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _replyTarget = null),
                    child: const Icon(Icons.close,
                        size: 16, color: ChatPalette.secondary),
                  ),
                ],
              ),
            ),
          if (_pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  for (var i = 0; i < _pending.length; i++)
                    Chip(
                      label: Text(_pending[i].ref.ext.toUpperCase(),
                          style: const TextStyle(fontSize: 10)),
                      onDeleted: () => setState(() => _pending.removeAt(i)),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              if (widget.onAttach != null)
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  color: ChatPalette.accent,
                  onPressed: _attach,
                ),
              Expanded(
                child: TextField(
                  controller: _input,
                  style: const TextStyle(color: Colors.white),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Reply…',
                    hintStyle: const TextStyle(color: ChatPalette.secondary),
                    filled: true,
                    fillColor: ChatPalette.inBubble,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                color: ChatPalette.accent,
                onPressed: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
