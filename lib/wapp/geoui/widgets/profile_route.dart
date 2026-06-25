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
  final void Function(Map<String, dynamic> post)? onPostTap;
  final VoidCallback? onMessage;
  final void Function(bool follow)? onSetFollow;
  final void Function(bool block)? onSetBlock;

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
    this.onPostTap,
    this.onMessage,
    this.onSetFollow,
    this.onSetBlock,
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
  List<Map<String, dynamic>>? _devices; // null = still loading / not requested

  @override
  void initState() {
    super.initState();
    if (widget.isSelf) {
      _applySelf();
    } else {
      _fetchRemote();
    }
    _loadDevices();
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
    setState(() {
      _name = (meta['name'] ?? meta['display_name'] ?? '').toString();
      _about = (meta['about'] ?? '').toString();
      if (picture.isNotEmpty) {
        _avatar = widget.resolveAvatar?.call(picture);
      }
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
      displayName: _name,
      about: _about,
      avatarImage: _avatar,
      isSelf: widget.isSelf,
      onEdit: widget.isSelf && widget.onEdit != null ? _edit : null,
      devices: _devices,
      showDevices: widget.fetchDevices != null,
    );
  }
}
