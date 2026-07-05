// A route wrapper around [ProfileView] that resolves profile metadata before
// (and as) it renders:
//   • our OWN profile is read synchronously from the local identity, and an
//     Edit action opens the editor then re-reads it;
//   • another station's profile is fetched asynchronously by npub from the
//     NOSTR relay (kind-0 note) — name/about appear when they arrive, and the
//     picture token is resolved to an avatar over the media swarm.
//
// App-agnostic: all data + side effects come in as callbacks from the wapp page.

import 'package:flutter/material.dart';

import 'profile_view.dart';

typedef SelfData = ({String? name, String? about, ImageProvider? avatar});

class ProfileRoute extends StatefulWidget {
  final String callsign;
  final String? npub;
  final bool isSelf;
  final int? firstSeenMs;
  final int postCount;
  final List<Map<String, dynamic>> posts;
  final bool following;
  final bool blocked;
  final bool muted;
  final void Function(Map<String, dynamic> post)? onPostTap;
  final VoidCallback? onMessage;
  final void Function(bool follow)? onSetFollow;
  final void Function(bool block)? onSetBlock;
  final void Function(bool mute)? onSetMute;

  /// Per-post social actions (Like / Reply / Retweet), forwarded to ProfileView.
  final ({int count, bool mine}) Function(String mid)? likeInfo;
  final void Function(String mid, bool like)? onLike;
  final int Function(String mid)? replyCount;
  final void Function(Map<String, dynamic> post)? onReplyPost;
  final bool Function(String mid)? isReposted;
  final void Function(Map<String, dynamic> post)? onRepost;
  final String? Function(String npub)? mentionResolver;

  /// Profile metadata supplied DIRECTLY (e.g. a NOSTR kind-0 already cached by
  /// the wapp): {name, about, pic, banner, nip05, website, lud16}. When present
  /// it's applied synchronously and [fetchMetadata] is not called.
  final Map<String, String>? metadata;

  /// Name + avatar already resolved by the caller (exactly what the feed shows),
  /// used to seed the header so it's NEVER blank while richer data loads.
  final String? presetName;
  final ImageProvider? presetAvatar;

  /// Read our own profile (name/about/avatar). Called on open and after editing.
  final SelfData Function()? loadSelf;

  /// Open the profile editor + publish the updated kind-0 note. Awaited so the
  /// view can re-read [loadSelf] when it returns.
  final Future<void> Function()? onEdit;

  /// Fetch another station's kind-0 metadata map ({name, about, picture}).
  final Future<Map<String, dynamic>?> Function()? fetchMetadata;

  /// Resolve a `file:<sha>.<ext>` media token to an avatar image (or null if the
  /// bytes aren't held yet; may kick off a swarm fetch as a side effect).
  final ImageProvider? Function(String token)? resolveAvatar;

  /// Fetch the Reticulum devices this user has been seen on, each
  /// {dest, hops, ageSec, online, services, via}. Shown as a "Reticulum devices"
  /// section in the panel; null hides the section.
  final Future<List<Map<String, dynamic>>> Function()? fetchDevices;

  const ProfileRoute({
    super.key,
    required this.callsign,
    this.npub,
    this.isSelf = false,
    this.firstSeenMs,
    this.postCount = 0,
    this.posts = const [],
    this.following = false,
    this.blocked = false,
    this.muted = false,
    this.onPostTap,
    this.onMessage,
    this.onSetFollow,
    this.onSetBlock,
    this.onSetMute,
    this.likeInfo,
    this.onLike,
    this.replyCount,
    this.onReplyPost,
    this.isReposted,
    this.onRepost,
    this.mentionResolver,
    this.metadata,
    this.presetName,
    this.presetAvatar,
    this.loadSelf,
    this.onEdit,
    this.fetchMetadata,
    this.resolveAvatar,
    this.fetchDevices,
  });

  @override
  State<ProfileRoute> createState() => _ProfileRouteState();
}

class _ProfileRouteState extends State<ProfileRoute> {
  String? _name;
  String? _about;
  ImageProvider? _avatar;
  ImageProvider? _banner;
  String? _nip05;
  String? _website;
  String? _lud16;
  List<Map<String, dynamic>>? _devices; // null = still loading / not requested

  @override
  void initState() {
    super.initState();
    // Seed with the feed's already-resolved name/avatar so the header is never
    // blank, then layer richer metadata (banner, links) on top.
    _name = widget.presetName;
    _avatar = widget.presetAvatar;
    if (widget.isSelf) {
      _applySelf();
    } else {
      if (widget.metadata != null) _applyMetadata(widget.metadata!);
      // Always try a fresh fetch too — fills banner/links/name if the preset or
      // cached metadata was sparse.
      _fetchRemote();
    }
    _loadDevices();
  }

  void _applyMetadata(Map<String, String> m) {
    ImageProvider? img(String? url) =>
        (url != null && url.startsWith('http')) ? NetworkImage(url) : null;
    setState(() {
      final n = (m['name'] ?? '').trim();
      if (n.isNotEmpty) _name = n;
      if ((m['about'] ?? '').isNotEmpty) _about = m['about'];
      final a = img(m['pic']);
      if (a != null) _avatar = a; // never blank a seeded avatar
      final b = img(m['banner']);
      if (b != null) _banner = b;
      if ((m['nip05'] ?? '').isNotEmpty) _nip05 = m['nip05'];
      if ((m['website'] ?? '').isNotEmpty) _website = m['website'];
      if ((m['lud16'] ?? '').isNotEmpty) _lud16 = m['lud16'];
    });
  }

  Future<void> _loadDevices() async {
    final fetch = widget.fetchDevices;
    if (fetch == null) return;
    final d = await fetch();
    if (!mounted) return;
    setState(() => _devices = d);
  }

  void _applySelf() {
    final d = widget.loadSelf?.call();
    if (d == null) return;
    setState(() {
      _name = d.name;
      _about = d.about;
      _avatar = d.avatar;
    });
  }

  Future<void> _fetchRemote() async {
    final fetch = widget.fetchMetadata;
    if (fetch == null) return;
    final meta = await fetch();
    if (!mounted || meta == null) return;
    final picture = (meta['picture'] ?? '').toString();
    final banner = (meta['banner'] ?? '').toString();
    setState(() {
      final n = (meta['name'] ?? meta['display_name'] ?? '').toString().trim();
      if (n.isNotEmpty) _name = n; // don't blank a seeded name
      if ((meta['about'] ?? '').toString().isNotEmpty) {
        _about = meta['about'].toString();
      }
      if (picture.isNotEmpty) {
        final a = widget.resolveAvatar?.call(picture);
        if (a != null) _avatar = a;
      }
      if (banner.startsWith('http')) _banner = NetworkImage(banner);
      if ((meta['nip05'] ?? '').toString().isNotEmpty) {
        _nip05 = meta['nip05'].toString();
      }
      if ((meta['website'] ?? '').toString().isNotEmpty) {
        _website = meta['website'].toString();
      }
      final lud = (meta['lud16'] ?? meta['lud06'] ?? '').toString();
      if (lud.isNotEmpty) _lud16 = lud;
    });
  }

  Future<void> _edit() async {
    await widget.onEdit?.call();
    if (mounted) _applySelf();
  }

  @override
  Widget build(BuildContext context) {
    return ProfileView(
      callsign: widget.callsign,
      npub: widget.npub,
      firstSeenMs: widget.firstSeenMs,
      postCount: widget.postCount,
      posts: widget.posts,
      onPostTap: widget.onPostTap,
      onMessage: widget.onMessage,
      following: widget.following,
      blocked: widget.blocked,
      onSetFollow: widget.onSetFollow,
      onSetBlock: widget.onSetBlock,
      onSetMute: widget.onSetMute,
      muted: widget.muted,
      likeInfo: widget.likeInfo,
      onLike: widget.onLike,
      replyCount: widget.replyCount,
      onReplyPost: widget.onReplyPost,
      isReposted: widget.isReposted,
      onRepost: widget.onRepost,
      mentionResolver: widget.mentionResolver,
      displayName: _name,
      about: _about,
      avatarImage: _avatar,
      bannerImage: _banner,
      nip05: _nip05,
      website: _website,
      lud16: _lud16,
      isSelf: widget.isSelf,
      onEdit: widget.isSelf && widget.onEdit != null ? _edit : null,
      devices: _devices,
      showDevices: widget.fetchDevices != null,
    );
  }
}
