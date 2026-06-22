// A full, Twitter/X-style profile page for a station: a header with avatar,
// callsign, npub, "first seen" date and post count, then the stream of posts
// that station has written (from the Activity archive). App-agnostic — it just
// renders the data it's handed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../util/media_ref.dart';
import '../../shared_media_fetch.dart' show mediaSizeHint;
import 'chat_view_field.dart' show viaTagColor;
import 'media_view.dart';

class ProfileView extends StatefulWidget {
  final String callsign;
  final String? npub;
  final int? firstSeenMs;
  final int postCount;
  final List<Map<String, dynamic>> posts; // oldest→newest
  final void Function(Map<String, dynamic> post)? onPostTap;
  final VoidCallback? onMessage;

  /// Current relationship + actions (wired to the APRS wapp). When the callbacks
  /// are null the corresponding control is hidden.
  final bool following;
  final bool blocked;
  final void Function(bool follow)? onSetFollow;
  final void Function(bool block)? onSetBlock;

  /// Profile metadata (from a NOSTR kind-0 note — ours locally, others fetched
  /// by npub). All optional; when absent we fall back to the callsign.
  final String? displayName; // kind-0 "name" / nickname
  final String? about; // kind-0 "about" / description
  final ImageProvider? avatarImage; // kind-0 "picture" resolved to an image

  /// This is OUR own profile: show an Edit button instead of Follow/Block.
  final bool isSelf;
  final VoidCallback? onEdit;

  const ProfileView({
    super.key,
    required this.callsign,
    this.npub,
    this.firstSeenMs,
    this.postCount = 0,
    this.posts = const [],
    this.onPostTap,
    this.onMessage,
    this.following = false,
    this.blocked = false,
    this.onSetFollow,
    this.onSetBlock,
    this.displayName,
    this.about,
    this.avatarImage,
    this.isSelf = false,
    this.onEdit,
  });

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  late bool _following = widget.following;
  late bool _blocked = widget.blocked;

  String get callsign => widget.callsign;
  String? get npub => widget.npub;
  int? get firstSeenMs => widget.firstSeenMs;
  int get postCount => widget.postCount;
  List<Map<String, dynamic>> get posts => widget.posts;

  /// Display name = nickname from the profile note, else the callsign.
  String get _name => widget.displayName?.trim().isNotEmpty == true
      ? widget.displayName!.trim()
      : callsign;
  String get _about => widget.about?.trim() ?? '';

  void _toggleFollow() {
    setState(() => _following = !_following);
    widget.onSetFollow?.call(_following);
  }

  void _toggleBlock() {
    setState(() => _blocked = !_blocked);
    widget.onSetBlock?.call(_blocked);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final newest = posts.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName?.trim().isNotEmpty == true
            ? widget.displayName!.trim()
            : callsign),
        actions: [
          if (widget.onSetBlock != null)
            PopupMenuButton<String>(
              onSelected: (_) => _toggleBlock(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'block',
                  child: Row(
                    children: [
                      Icon(_blocked ? Icons.check_circle_outline : Icons.block,
                          size: 18,
                          color: _blocked ? null : Colors.red),
                      const SizedBox(width: 8),
                      Text(_blocked ? 'Unblock $callsign' : 'Block $callsign',
                          style:
                              TextStyle(color: _blocked ? null : Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _header(context, cs),
              Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
              if (newest.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('No posts from $callsign yet.',
                        style:
                            TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                  ),
                )
              else
                for (final p in newest) ...[
                  _postRow(cs, p),
                  Divider(height: 1, color: cs.outlineVariant.withAlpha(45)),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(callsign, 32),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold)),
                    // Callsign as secondary line when a nickname is shown.
                    if (_name != callsign)
                      Text(callsign,
                          style: TextStyle(
                              color: Colors.white.withAlpha(140),
                              fontSize: 13)),
                    if (npub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: npub!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('npub copied'),
                                  duration: Duration(seconds: 1)),
                            );
                          },
                          child: Text(
                            npub!.length > 22
                                ? '${npub!.substring(0, 12)}…${npub!.substring(npub!.length - 6)}'
                                : npub!,
                            style: TextStyle(
                                color: cs.primary, fontSize: 12.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.isSelf && widget.onEdit != null)
                    OutlinedButton.icon(
                      onPressed: widget.onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit profile'),
                    ),
                  if (!widget.isSelf && widget.onSetFollow != null)
                    _followButton(cs),
                  if (!widget.isSelf && widget.onMessage != null) ...[
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: widget.onMessage,
                      icon: const Icon(Icons.mail_outline, size: 16),
                      label: const Text('Message'),
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (_about.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_about,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14, height: 1.35)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 5),
              Text('First seen ${_firstSeen()}',
                  style:
                      TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
              const SizedBox(width: 16),
              Text('$postCount ${postCount == 1 ? 'post' : 'posts'}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12.5)),
            ],
          ),
          if (_blocked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.block, size: 14, color: Colors.red),
                  const SizedBox(width: 5),
                  Text('Blocked — their messages are hidden',
                      style: TextStyle(color: Colors.red.withAlpha(200), fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _followButton(ColorScheme cs) {
    if (_following) {
      return OutlinedButton(
        onPressed: _toggleFollow,
        child: const Text('Following'),
      );
    }
    return FilledButton(
      onPressed: _toggleFollow,
      style: FilledButton.styleFrom(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: const Text('Follow'),
    );
  }

  String _firstSeen() {
    final ms = firstSeenMs;
    if (ms == null || ms == 0) return 'unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _postRow(ColorScheme cs, Map<String, dynamic> p) {
    final raw = (p['text'] ?? '').toString();
    final time = (p['time'] ?? '').toString();
    final via = (p['via'] ?? '').toString();
    final convo = (p['convo'] ?? '').toString();
    final body = _stripTokens(raw);
    final refs = MediaRef.findAll(raw);
    final tappable = widget.onPostTap != null && convo.isNotEmpty;
    return InkWell(
      onTap: tappable ? () => widget.onPostTap!(p) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (time.isNotEmpty || via.isNotEmpty)
              Row(
                children: [
                  if (time.isNotEmpty)
                    Text(time,
                        style: TextStyle(
                            color: Colors.white.withAlpha(120), fontSize: 12)),
                  if (via.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _viaChip(via),
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
                    for (final r in refs)
                      MediaThumbnail(
                          ref: r, size: mediaSizeHint(raw), from: callsign),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _viaChip(String via) {
    final c = viaTagColor(via);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withAlpha(120), width: 0.6),
      ),
      child: Text(via.toUpperCase(),
          style:
              TextStyle(color: c, fontSize: 8.5, fontWeight: FontWeight.w700)),
    );
  }

  Widget _avatar(String call, double radius) {
    // A real avatar image (from the profile's kind-0 "picture") wins; otherwise
    // fall back to coloured initials.
    if (widget.avatarImage != null) {
      return CircleAvatar(radius: radius, backgroundImage: widget.avatarImage);
    }
    final initials = call.isEmpty
        ? '?'
        : call
            .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
            .padRight(2)
            .substring(0, 2)
            .toUpperCase();
    final hue = (call.codeUnits.fold<int>(0, (a, b) => a + b) * 47) % 360;
    return CircleAvatar(
      radius: radius,
      backgroundColor: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.4).toColor(),
      child: Text(initials,
          style: TextStyle(
              color: Colors.white,
              fontSize: radius * 0.7,
              fontWeight: FontWeight.bold)),
    );
  }

  static final _fileRe = RegExp(r'file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}');
  static String _stripTokens(String s) => s
      .replaceAll(_fileRe, '')
      .replaceAll(RegExp(r'\bih:[0-9a-fA-F]{40}\b'), '')
      .replaceAll(RegExp(r'\bsz:\d+\b'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
