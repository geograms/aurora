// Twitter/X-style Activity feed: a compose box pinned at the TOP ("What's
// happening?"), then a centered, single-column stream of posts as cards (avatar,
// callsign, time, origin chip, text, image/video thumbnails). Tapping a post
// opens its conversation; tapping a name opens the profile. App-agnostic — it
// just renders the post maps it's given and reports compose/attach/taps back.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:ui' as ui;

import '../../../services/media_disk_cache.dart';
import '../../../services/reticulum/rns_service.dart';
import '../../native/wasm_video_player.dart';
import 'package:http/http.dart' as http;

import '../../../util/blurhash.dart';
import '../../../util/media_ref.dart';
import '../../../util/nostr_imeta.dart';
import '../../../util/time_ago.dart';
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
  final bool Function(String mid)? isReposted;
  final void Function(Map<String, dynamic> post)? onRepost;
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

  /// Resolve a `npub1…` mention in a post body to a display name.
  final String? Function(String npub)? mentionResolver;

  /// Pull-to-refresh: re-query the relays for the latest posts. Awaited so the
  /// spinner shows until new events have had a moment to arrive.
  final Future<void> Function()? onRefresh;

  /// Persisted tab choice to open on: 'all' | 'following' | 'favorites'.
  /// Null/unknown → 'all'. Changes are reported via [onFilterChanged].
  final String? initialFilter;
  final ValueChanged<String>? onFilterChanged;

  /// Read-only mode (search results): no composer, no All/Following bar, no
  /// "new posts" pill — just the tappable post/result cards, shown as-is.
  final bool readOnly;

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
    this.isReposted,
    this.onRepost,
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
    this.mentionResolver,
    this.onRefresh,
    this.initialFilter,
    this.onFilterChanged,
    this.readOnly = false,
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
  final _composeFocus = FocusNode();
  final _pending = <({String token, MediaRef ref})>[];
  late _ActivityFilter _filter;
  bool _composing = false; // collapsed single-line composer until tapped

  final _scroll = ScrollController();
  // The FROZEN post snapshot the list renders. While the user is scrolled down,
  // new posts are held out of this list (so the screen doesn't shift under them)
  // and surfaced via the "N new posts" pill.
  List<Map<String, dynamic>> _shown = const [];
  int _newCount = 0;

  bool get _atTop => !_scroll.hasClients || _scroll.offset <= 12;

  void _onScroll() {
    // Reaching the top adopts whatever arrived while reading below.
    if (_atTop && _newCount > 0) _pullNew(scroll: false);
  }

  /// Show the freshest posts: adopt the latest list + jump to the top.
  void _pullNew({bool scroll = true}) {
    setState(() {
      _shown = widget.posts;
      _newCount = 0;
    });
    if (scroll && _scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  static _ActivityFilter _filterFromString(String? s) => switch (s) {
        'following' => _ActivityFilter.following,
        'favorites' => _ActivityFilter.favorites,
        _ => _ActivityFilter.all,
      };
  static String _filterToString(_ActivityFilter f) => switch (f) {
        _ActivityFilter.following => 'following',
        _ActivityFilter.favorites => 'favorites',
        _ActivityFilter.all => 'all',
      };

  @override
  void initState() {
    super.initState();
    // Seed ONCE from the persisted choice; never in didUpdateWidget (the widget
    // rebuilds on every archive update — that would stomp the in-session tab).
    _filter = _filterFromString(widget.initialFilter);
    _shown = widget.posts; // show cached posts immediately
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ActivityFeed old) {
    super.didUpdateWidget(old);
    if (identical(old.posts, widget.posts)) return;
    if (_atTop) {
      // At the top → keep it live (new posts just appear, no jump).
      _shown = widget.posts;
      _newCount = 0;
      return;
    }
    // Scrolled down → hold the new posts back; count how many (of the ones that
    // pass the current filter) are waiting, to label the pill.
    final shownMids = {
      for (final p in _filtered(_shown)) (p['mid'] ?? '').toString()
    };
    var n = 0;
    for (final p in _filtered(widget.posts)) {
      if (!shownMids.contains((p['mid'] ?? '').toString())) n++;
    }
    _newCount = n;
  }

  @override
  void dispose() {
    _input.dispose();
    _composeFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _expandComposer() {
    setState(() => _composing = true);
    _composeFocus.requestFocus();
  }

  void _collapseComposer() {
    if (_input.text.trim().isEmpty && _pending.isEmpty) {
      _composeFocus.unfocus();
      setState(() => _composing = false);
    }
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
    _composeFocus.unfocus();
    setState(() => _composing = false);
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

  /// Apply the current All/Following/Saved filter to a raw post list, newest
  /// first. Kept separate so the "N new posts" count can be measured against the
  /// same filtered view the user actually sees.
  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> src) {
    List<Map<String, dynamic>> posts;
    switch (_filter) {
      case _ActivityFilter.favorites:
        // Bookmarked posts come from the saved store, already newest-first.
        posts = widget.savedPosts?.call() ?? const [];
        break;
      case _ActivityFilter.following:
        // Everything the people I follow do — their posts AND their replies to
        // others (their interactions), so NOT gated to roots. Scoped strictly
        // to accounts I follow (+ my own posts).
        posts = src.reversed.where((p) {
          if (!_isStreamPost(p)) return false;
          final from = (p['from'] ?? '').toString().toUpperCase();
          final out = (p['dir'] ?? '') == 'out';
          return out || widget.followedCalls.contains(from);
        }).toList();
        break;
      case _ActivityFilter.all:
        // Everything happening now: root posts, newest first, from anyone.
        //
        // This used to require `pop==1 || likes>=2` — i.e. "All" meant "roots
        // that already collected two likes". A post cannot have likes the moment
        // it is published, so no fresh post could EVER appear here, and the tab
        // whose whole job is discovering people you don't follow yet showed you
        // hour-old material. The like gate was standing in for spam filtering and
        // doing it badly; the host's quality gate (feed_quality.dart) does that
        // job properly now, upstream, before a post ever reaches this widget.
        posts = src.reversed
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
    return posts;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Read-only (search results): show all posts as-is; no live snapshot games.
    // Otherwise render the FROZEN snapshot (so new posts don't shove the screen
    // while the user reads); the "N new posts" pill pulls the fresh ones in.
    final posts = widget.readOnly
        ? widget.posts.reversed
            .where((p) => !widget.hiddenCalls
                .contains((p['from'] ?? '').toString().toUpperCase()))
            .toList()
        : _filtered(_shown);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          children: [
            // Filter sits right below the nav tabs (Activity/Messages/…), with
            // the composer card underneath it (its own tinted box + margins set
            // it apart from the stream — no extra dividers needed).
            if (!widget.readOnly) ...[
              _filterBar(cs),
              Divider(height: 1, color: cs.outlineVariant.withAlpha(45)),
              _composer(cs),
              if (_newCount > 0) _newPostsPill(cs),
            ],
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await widget.onRefresh?.call();
                  // Give freshly-requested events a beat to land before the
                  // spinner retracts, so the user sees the stream update.
                  await Future<void>.delayed(const Duration(milliseconds: 900));
                },
                child: posts.isEmpty
                    ? ListView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          widget.readOnly
                              ? Center(
                                  child: Text('No results.',
                                      style: TextStyle(
                                          color: cs.onSurfaceVariant
                                              .withAlpha(150))))
                              : _empty(cs),
                        ],
                      )
                    : ListView.separated(
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        physics: const AlwaysScrollableScrollPhysics(),
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
                          isReposted: widget.isReposted,
                          onRepost: widget.onRepost,
                          replyCount: widget.replyCount,
                          onBlock: widget.onBlock,
                          onMute: widget.onMute,
                          onTap: () => widget.onOpenThread?.call(posts[i]),
                          onReply: () => widget.onOpenThread?.call(posts[i]),
                          mentionResolver: widget.mentionResolver,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A tappable "N new posts" pill under the composer. Tapping pulls the fresh
  /// posts in and scrolls to the top — new posts never move the screen on their
  /// own while the user is reading below.
  Widget _newPostsPill(ColorScheme cs) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Center(
          child: Material(
            color: ChatPalette.accent,
            borderRadius: BorderRadius.circular(20),
            elevation: 2,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _pullNew(),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.arrow_upward, size: 15, color: Colors.white),
                  const SizedBox(width: 6),
                  Text('$_newCount new post${_newCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ),
      );

  /// Filter the noise: everything, only people you follow, or your bookmarks.
  Widget _filterBar(ColorScheme cs) {
    Widget tab(IconData icon, String label, _ActivityFilter value) {
      final selected = _filter == value;
      final color = selected ? ChatPalette.accent : ChatPalette.secondary;
      return InkWell(
        onTap: () {
          setState(() => _filter = value);
          widget.onFilterChanged?.call(_filterToString(value));
        },
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
    // Collapsed: a single-line tappable pill so the feed isn't pushed down.
    if (!_composing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: _expandComposer,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: ChatPalette.inBubble,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: ChatPalette.accent.withAlpha(45)),
            ),
            child: Row(
              children: [
                GestureDetector(
                    onTap: widget.onSelfTap, child: _avatar('', cs, me: true)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(widget.hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withAlpha(110), fontSize: 15)),
                ),
                Icon(Icons.send,
                    size: 18, color: ChatPalette.accent),
              ],
            ),
          ),
        ),
      );
    }
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
                  focusNode: _composeFocus,
                  autofocus: true,
                  onTapOutside: (_) => _collapseComposer(),
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

/// Human label for a post's time — [timeAgo], plus this feed's own fallback:
/// with no epoch (`t`, ms) there is nothing to be relative to, so the wapp's
/// `time` clock string stands in. Same wording as the launcher hero.
String activityTimeLabel(Map<String, dynamic> p) {
  final time = (p['time'] ?? '').toString();
  final t = (p['t'] as num?)?.toInt() ?? 0;
  if (t <= 0) return time; // no absolute time — keep the wapp's clock string
  final dt = DateTime.fromMillisecondsSinceEpoch(t);
  final label = timeAgo(dt);
  // Future-skew (bad clock): prefer the clock string when the wapp gave us one.
  if (label == 'now' && time.isNotEmpty) return time;
  return label;
}

/// Compact time for the crowded post header ("now", "18m", "2h", "3d", "Jun 26")
/// so the author name gets the room it needs.
String activityTimeShort(Map<String, dynamic> p) {
  final t = (p['t'] as num?)?.toInt() ?? 0;
  if (t <= 0) return (p['time'] ?? '').toString();
  final dt = DateTime.fromMillisecondsSinceEpoch(t);
  final now = DateTime.now();
  final secs = now.difference(dt).inSeconds;
  if (secs < -60) return 'now';
  if (secs < 60) return 'now';
  if (secs < 3600) return '${secs ~/ 60}m';
  if (secs < 86400) return '${secs ~/ 3600}h';
  final days = secs ~/ 86400;
  if (days < 7) return '${days}d';
  final mon = _activityMonths[dt.month - 1];
  return dt.year == now.year ? '$mon ${dt.day}' : '$mon ${dt.day} ${dt.year}';
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

  /// Repost (kind-6 "retweet"): whether we've reposted, and the toggle action.
  final bool Function(String mid)? isReposted;
  final void Function(Map<String, dynamic> post)? onRepost;

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

  /// Resolve a `npub1…` mention in the body to a display name.
  final String? Function(String npub)? mentionResolver;

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
    this.isReposted,
    this.onRepost,
    this.onBlock,
    this.onMute,
    this.onTap,
    this.onReply,
    this.indent = 0,
    this.connector = false,
    this.mentionResolver,
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
    final time = activityTimeShort(p);
    final via = (p['via'] ?? '').toString();
    final body =
        activityFormatMentions(activityStrip(raw), mentionResolver);
    // Media links shown inline below are stripped from the visible text (no
    // point repeating a long blossom.band/… URL under its own image).
    final mediaUrls = activityMediaUrls(body);
    // NIP-92 imeta (video poster / blurhash / dimensions) — carried on the
    // post, or recovered once from the local relay store for older rows.
    var imeta = imetaFromMeta((p['meta'] ?? '').toString());
    if (imeta.isEmpty && mediaUrls.isNotEmpty) imeta = _imetaByMid(mid);
    final textBody = mediaUrls.isEmpty ? body : _stripMediaUrls(body, mediaUrls);
    final refs = MediaRef.findAll(raw);
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
                      // Name gets ALL the room left after the (compact) time +
                      // via chip; the "…" menu sits at the far right without
                      // competing for the name's width. No npub beside the name —
                      // the name is the only thing people can read.
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: GestureDetector(
                                onTap: (onSenderTap != null && from.isNotEmpty)
                                    ? () => onSenderTap!(from)
                                    : null,
                                child: Text(displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                              ),
                            ),
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
                          ],
                        ),
                      ),
                      if (from.isNotEmpty &&
                          (p['dir'] ?? '') != 'out' &&
                          (onBlock != null || onMute != null))
                        SizedBox(height: 22, width: 28, child: _menu(from)),
                    ],
                  ),
                  if (textBody.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      // Long notes (some are thousands of chars) are clamped with
                      // a "More" toggle so one post can't blow up the row.
                      child: _ExpandableText(textBody,
                          key: ValueKey('body-${mid.isNotEmpty ? mid : '$from$body'.hashCode}')),
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
                  // Plain http(s) image/video links in the text (NOSTR posts,
                  // etc.) are fetched + shown inline (≤10 MB) or offered as a
                  // tap-to-download card.
                  for (final url in mediaUrls)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _RemoteMedia(url,
                          imeta: imeta[url], key: ValueKey('rm-$url')),
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
            Icons.repeat,
            null,
            (isReposted?.call(mid) ?? false)
                ? const Color(0xFF00BA7C)
                : muted,
            onRepost == null ? null : () => onRepost!(post),
          ),
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
  final bool Function(String mid)? isReposted;
  final void Function(Map<String, dynamic> post)? onRepost;

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

  /// Resolve a `npub1…` mention in a post body to a display name.
  final String? Function(String npub)? mentionResolver;

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
    this.isReposted,
    this.onRepost,
    this.onSenderTap,
    this.profileFor,
    this.npubFor,
    this.onAttach,
    this.revision,
    this.mentionResolver,
  });

  @override
  State<ActivityThreadPage> createState() => _ActivityThreadPageState();
}

class _ActivityThreadPageState extends State<ActivityThreadPage> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
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
    _inputFocus.dispose();
    super.dispose();
  }

  /// Aim the composer at [post] (null = the root) and pop the keyboard open.
  void _replyTo(Map<String, dynamic>? post) {
    setState(() => _replyTarget = post);
    _inputFocus.requestFocus();
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
                      isReposted: widget.isReposted,
                      onRepost: widget.onRepost,
                      replyCount: widget.replyCount,
                      indent: depth * 16.0,
                      connector: depth > 0,
                      mentionResolver: widget.mentionResolver,
                      // Reply to the root itself targets the publication (null).
                      onReply: () =>
                          _replyTo(i == 0 ? null : it.post),
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
                  focusNode: _inputFocus,
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

/// A post body that clamps very long notes (some relays carry thousands of
/// characters) to a preview with a "More" toggle, so one post can't dominate
/// the feed. State is keyed by the post id so it survives list rebuilds.
class _ExpandableText extends StatefulWidget {
  final String text;
  const _ExpandableText(this.text, {super.key});
  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;
  static const int _limit = 560;
  final List<TapGestureRecognizer> _recognizers = [];

  static final _urlRe = RegExp(r'https?://[^\s]+', caseSensitive: false);

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Split [text] into plain runs + tappable http(s) link spans (opened in the
  /// system browser). Trailing punctuation stays out of the link.
  List<InlineSpan> _linkified(String text) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in _urlRe.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      var url = m.group(0)!;
      String tail = '';
      final tm = RegExp(r'[.,;:!?)\]}>"' r"']+$").firstMatch(url);
      if (tm != null) {
        tail = url.substring(tm.start);
        url = url.substring(0, tm.start);
      }
      final rec = TapGestureRecognizer()..onTap = () => _openUrl(url);
      _recognizers.add(rec);
      spans.add(TextSpan(
        text: url,
        recognizer: rec,
        style: TextStyle(
            color: ChatPalette.accent, decoration: TextDecoration.underline),
      ));
      if (tail.isNotEmpty) spans.add(TextSpan(text: tail));
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.text;
    final long = t.length > _limit;
    final shown =
        (_expanded || !long) ? t : '${t.substring(0, _limit).trimRight()}…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
            TextSpan(children: _linkified(shown)),
            style: const TextStyle(
                color: Colors.white, fontSize: 14, height: 1.3)),
        if (long)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_expanded ? 'Less' : 'More',
                  style: const TextStyle(
                      color: ChatPalette.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ),
      ],
    );
  }
}

// ── Inline remote media (plain http image/video links in post text) ──────────

final _activityMediaRe = RegExp(
    r'https?://[^\s]+?\.(?:jpg|jpeg|png|gif|webp|bmp|mp4|mov|webm|m4v)(?:\?[^\s]*)?',
    caseSensitive: false);

/// Up to 4 distinct http(s) image/video URLs mentioned in a post body.
List<String> activityMediaUrls(String body) {
  final out = <String>[];
  for (final m in _activityMediaRe.allMatches(body)) {
    final u = m.group(0)!;
    if (!out.contains(u)) out.add(u);
    if (out.length >= 4) break;
  }
  return out;
}

final _activityMentionRe = RegExp(
    r'nostr:((?:npub1|nprofile1|nevent1|note1|naddr1)[023456789acdefghjklmnpqrstuvwxyz]{20,})',
    caseSensitive: false);

/// Turn NIP-19 `nostr:` references into readable text:
///   • `npub1…` / `nprofile1…`  → `@Name` (via [resolve]) or a short `@npub1…`,
///   • `nevent1…` / `note1…` / `naddr1…` → a compact `↗ note` (a quoted note),
/// instead of dumping the raw 60-char bech32 string into the post.
String activityFormatMentions(String body, String? Function(String npub)? resolve) {
  if (!body.contains('nostr:')) return body;
  return body.replaceAllMapped(_activityMentionRe, (m) {
    final token = m.group(1)!;
    final lower = token.toLowerCase();
    if (lower.startsWith('npub1') || lower.startsWith('nprofile1')) {
      final name = resolve?.call(token);
      if (name != null && name.isNotEmpty) return '@$name';
      return '@${token.substring(0, 10)}…';
    }
    return '↗ note'; // nevent / note / naddr — a reference to another note
  });
}

/// Remove the media URLs (shown inline below) from the visible post text.
String _stripMediaUrls(String body, List<String> urls) {
  var s = body;
  for (final u in urls) {
    s = s.replaceAll(u, '');
  }
  // Tidy up doubled spaces / trailing whitespace left behind.
  return s.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
}

bool _isVideoUrl(String u) {
  final l = u.toLowerCase().split('?').first;
  return l.endsWith('.mp4') ||
      l.endsWith('.mov') ||
      l.endsWith('.webm') ||
      l.endsWith('.m4v');
}

enum _RmState { checking, show, tooBig, error }

/// Human byte size: "12.3 MB", "1.4 GB", "840 KB".
String _fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

/// Fetches + renders a media URL inline. Auto-loads when ≤10 MB (or unknown);
/// larger files show a tap-to-download card so a big image can't auto-pull on
/// cellular. Videos are always a tap-to-open card (no inline player).
// Memoized mid → imeta recovered from the local relay store. The feed
// rebuilds every tick, so cache hits AND misses (empty maps).
final Map<String, Map<String, Map<String, String>>> _imetaMidCache = {};

Map<String, Map<String, String>> _imetaByMid(String mid) {
  if (mid.length != 64) return const {}; // only real NOSTR event ids
  final hit = _imetaMidCache[mid];
  if (hit != null) return hit;
  var out = const <String, Map<String, String>>{};
  try {
    final tags = RnsService.instance.relayLocalEvent(mid)?['tags'];
    if (tags is List) out = imetaFromTags(tags);
  } catch (_) {}
  if (_imetaMidCache.length > 800) _imetaMidCache.clear();
  _imetaMidCache[mid] = out;
  return out;
}

class _RemoteMedia extends StatefulWidget {
  final String url;

  /// NIP-92 imeta for this url (`image` poster, `blurhash`, `dim`, `dur`) —
  /// lets a video show a real thumbnail before anything big is downloaded.
  final Map<String, String>? imeta;
  const _RemoteMedia(this.url, {this.imeta, super.key});
  @override
  State<_RemoteMedia> createState() => _RemoteMediaState();
}

class _RemoteMediaState extends State<_RemoteMedia> {
  static const int _cap = 10 * 1024 * 1024;
  static const int _vidCap = 500 * 1024 * 1024;
  late final bool _isVid = _isVideoUrl(widget.url);
  _RmState _s = _RmState.checking;
  Uint8List? _bytes; // decoded image OR fetched video bytes
  bool _playing = false; // video: user tapped play
  int _dlTotal = 0; // video size in bytes (0 = unknown)
  int _dlReceived = 0; // bytes downloaded so far
  bool _gone = false; // the host purged the file (HEAD said 4xx/5xx)

  // Poster (thumbnail) for the video play card: imeta `image` url, a locally
  // generated first-frame (cached after the first playback), with the imeta
  // blurhash painting instantly while a poster downloads.
  Uint8List? _poster;
  ui.Image? _blur;

  @override
  void initState() {
    super.initState();
    if (_isVid) {
      _s = _RmState.show; // show a play card; fetch the (big) video on tap only
      // Probe the size so the card can show "▶ 12.3 MB" before downloading.
      // -1 = the host purged the file (media hosts expire uploads) — say so
      // instead of offering a play button that can only fail.
      MediaDiskCache.instance.probeSize(widget.url).then((s) {
        if (!mounted) return;
        if (s > 0) setState(() => _dlTotal = s);
        if (s < 0) setState(() => _gone = true);
      });
      _loadPoster();
    } else {
      _load(_cap);
    }
  }

  Future<void> _loadPoster() async {
    final bh = widget.imeta?['blurhash'];
    if (bh != null && bh.isNotEmpty) {
      blurhashImage(bh).then((img) {
        if (mounted && img != null && _poster == null) {
          setState(() => _blur = img);
        }
      });
    }
    // Locally generated first-frame from an earlier playback wins (it's
    // already on disk); else fetch the post's poster image (small).
    var bytes = await MediaDiskCache.instance.peek('${widget.url}#poster');
    if (bytes == null) {
      final img = widget.imeta?['image'];
      if (img != null && img.isNotEmpty) {
        bytes = await MediaDiskCache.instance.fetch(img);
      }
    }
    if (mounted && bytes != null) setState(() => _poster = bytes);
  }

  String _extOf(String url) {
    final l = url.toLowerCase().split('?').first;
    final dot = l.lastIndexOf('.');
    return dot >= 0 ? l.substring(dot + 1) : 'mp4';
  }

  /// Fetch through the persistent disk cache (no re-download across sessions).
  Future<void> _load(int maxBytes) async {
    final bytes =
        await MediaDiskCache.instance.fetch(widget.url, maxBytes: maxBytes);
    if (!mounted) return;
    setState(() {
      if (bytes != null) {
        _bytes = bytes;
        _s = _RmState.show;
      } else {
        // Too big (or blocked) — offer a manual download.
        _s = _s == _RmState.checking ? _RmState.tooBig : _RmState.error;
      }
    });
  }

  /// Tap-to-play a video: stream its bytes with a live progress bar, then hand
  /// them to the shared WasmVideoPlayer (same player the Chat wapp uses).
  Future<void> _playVideo() async {
    setState(() {
      _playing = true;
      _dlReceived = 0;
      _s = _RmState.checking;
    });
    final bytes = await MediaDiskCache.instance.fetchStreamed(
      widget.url,
      maxBytes: _vidCap,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _dlReceived = received;
          if (total > 0) _dlTotal = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      if (bytes != null) {
        _bytes = bytes;
        _s = _RmState.show;
      } else {
        _s = _RmState.error;
      }
    });
    // First playback of a post with no poster: extract one from the now-local
    // bytes and cache it, so this video shows a real thumbnail from now on.
    if (bytes != null && _poster == null) {
      unawaited(() async {
        final png = await WasmVideoThumbnailer.generate(
            bytes, _extOf(widget.url));
        if (png == null) return;
        await MediaDiskCache.instance.putLocal('${widget.url}#poster', png);
        if (mounted && _poster == null) setState(() => _poster = png);
      }());
    }
  }

  /// Open the image full-screen with pinch-zoom (reuses the same viewer body as
  /// the Chat media viewer).
  void _openFullImage() {
    final img = _bytes;
    if (img == null) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _FullscreenImage(img), fullscreenDialog: true));
  }

  String get _sizeLabel => '';

  /// "38.6" (imeta duration, seconds) → "0:38"; null when absent/garbage.
  static String? _durLabel(String? dur) {
    final s = double.tryParse(dur ?? '');
    if (s == null || s <= 0) return null;
    final total = s.round();
    final m = total ~/ 60, sec = total % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  // A fixed media height so the row NEVER changes size as the image loads —
  // checking, loading and loaded all occupy exactly this box (no scroll jump).
  static const double _mediaHeight = 260;

  /// Live download bar for a video: "6.2 MB / 12.3 MB · 50%" with a progress
  /// bar (indeterminate when the server didn't report a total).
  Widget _downloadProgress(ColorScheme cs) {
    final known = _dlTotal > 0;
    final frac = known ? (_dlReceived / _dlTotal).clamp(0.0, 1.0) : null;
    final label = known
        ? '${_fmtBytes(_dlReceived)} / ${_fmtBytes(_dlTotal)} · ${((frac ?? 0) * 100).round()}%'
        : 'Downloading ${_fmtBytes(_dlReceived)}…';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.downloading, color: Colors.white70, size: 30),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 5,
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _box(ColorScheme cs, Widget child) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: _mediaHeight,
          width: double.infinity,
          color: cs.surfaceContainerHighest.withAlpha(35),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_s) {
      case _RmState.checking:
        // Reserve the box; show a spinner while a video's bytes download.
        return _box(cs, _playing ? _downloadProgress(cs) : const SizedBox.shrink());
      case _RmState.tooBig:
        // Large image: tap to download now (up to 200 MB).
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() => _s = _RmState.checking);
            _load(200 * 1024 * 1024);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withAlpha(70)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('Image — tap to load',
                      style: TextStyle(color: cs.onSurface, fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        );
      case _RmState.error:
        return _box(
            cs,
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                      _isVid
                          ? Icons.videocam_off_outlined
                          : Icons.broken_image_outlined,
                      color: cs.onSurfaceVariant.withAlpha(120),
                      size: 30),
                  if (_isVid)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Video unavailable (removed from the host)',
                          style: TextStyle(
                              color: cs.onSurfaceVariant.withAlpha(160),
                              fontSize: 12)),
                    ),
                ],
              ),
            ));
      case _RmState.show:
        // Video: a play card until tapped, then the shared WasmVideoPlayer.
        if (_isVid) {
          if (!_playing) {
            final dur = _durLabel(widget.imeta?['dur']);
            final chip = _gone
                ? 'video expired on the host'
                : [
                    if (dur != null) dur,
                    if (_dlTotal > 0) '${_fmtBytes(_dlTotal)} video',
                  ].join(' · ');
            return InkWell(
              onTap: _gone ? null : _playVideo,
              child: _box(
                cs,
                Container(
                  color: Colors.black,
                  child: Stack(
                    alignment: Alignment.center,
                    fit: StackFit.expand,
                    children: [
                      // Poster (imeta image / cached first-frame), with the
                      // blurhash painting the box while it downloads.
                      if (_poster != null)
                        Image.memory(_poster!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink())
                      else if (_blur != null)
                        RawImage(
                            image: _blur,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low),
                      // Dim so the play affordance reads on bright posters.
                      if (_poster != null || _blur != null)
                        Container(color: Colors.black26),
                      Center(
                        child: Icon(
                            _gone
                                ? Icons.videocam_off_outlined
                                : Icons.play_circle_fill,
                            size: 64,
                            color: Colors.white70),
                      ),
                      // "0:38 · 12.3 MB video", once known.
                      if (chip.isNotEmpty)
                        Positioned(
                          bottom: 8,
                          right: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(chip,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }
          final v = _bytes;
          if (v == null) return _box(cs, const SizedBox.shrink());
          // The player fills whatever box it is given (Stack.expand) — in the
          // unbounded feed column it MUST get a finite height or layout dies
          // ("BoxConstraints forces an infinite height", the long-standing
          // reason tapped videos showed a dead black card). imeta dim gives
          // the true aspect; otherwise keep the card's fixed height.
          final dim = widget.imeta?['dim']?.split('x');
          final dw = double.tryParse(dim?.first ?? '');
          final dh = double.tryParse((dim?.length ?? 0) > 1 ? dim![1] : '');
          final player = WasmVideoPlayer(mediaBytes: v, ext: _extOf(widget.url));
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: (dw != null && dh != null && dw > 0 && dh > 0)
                ? AspectRatio(
                    aspectRatio: (dw / dh).clamp(0.5, 2.2), child: player)
                : SizedBox(
                    height: _mediaHeight,
                    width: double.infinity,
                    child: player,
                  ),
          );
        }
        // Image: tap to open full-screen (pinch-zoom).
        final img = _bytes;
        if (img == null) return _box(cs, const SizedBox.shrink());
        return GestureDetector(
          onTap: _openFullImage,
          child: _box(
            cs,
            Image.memory(
              img,
              fit: BoxFit.cover,
              width: double.infinity,
              height: _mediaHeight,
              gaplessPlayback: true,
              cacheHeight: 720,
              errorBuilder: (c, e, s) => Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: cs.onSurfaceVariant.withAlpha(120), size: 30)),
            ),
          ),
        );
    }
  }
}

/// Full-screen pinch-zoom image viewer (same body as the Chat media viewer).
class _FullscreenImage extends StatelessWidget {
  final Uint8List bytes;
  const _FullscreenImage(this.bytes);
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      );
}
