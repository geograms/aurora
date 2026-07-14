// A full, Twitter/X-style profile page for a station: a header with avatar,
// callsign, npub, "first seen" date and post count, then the stream of posts
// that station has written (from the Activity archive). App-agnostic — it just
// renders the data it's handed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../util/media_ref.dart';
import '../../../services/social/note_text.dart';
import '../../shared_media_fetch.dart' show mediaSizeHint;
import 'activity_feed.dart' show activityFormatMentions;
import 'chat_view_field.dart' show viaTagColor;
import 'generated_avatar.dart';
import 'media_view.dart';

class ProfileView extends StatefulWidget {
  final String callsign;
  final String? npub;
  final int? firstSeenMs;
  final int postCount;
  final List<Map<String, dynamic>> posts; // oldest→newest
  final void Function(Map<String, dynamic> post)? onPostTap;
  final VoidCallback? onMessage;

  /// Per-post social actions (Like / Reply / Retweet), mirroring the feed. When
  /// a callback is null the corresponding control is hidden. Keyed by the post's
  /// `mid`.
  final ({int count, bool mine}) Function(String mid)? likeInfo;
  final void Function(String mid, bool like)? onLike;
  final int Function(String mid)? replyCount;
  final void Function(Map<String, dynamic> post)? onReplyPost;
  final bool Function(String mid)? isReposted;
  final void Function(Map<String, dynamic> post)? onRepost;
  final String? Function(String npub)? mentionResolver;

  /// Tapping an @mention in the bio or in a post opens that person.
  final void Function(String pubkeyHex)? onMentionTap;

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

  /// Extra kind-0 fields (all optional): a header banner image, a NIP-05
  /// verified address, a website URL and a lightning address (lud16).
  final ImageProvider? bannerImage;
  final String? nip05;
  final String? website;
  final String? lud16;

  /// Mute relationship + toggle (hides their posts without a full block). When
  /// [onSetMute] is null the control is hidden.
  final bool muted;
  final void Function(bool mute)? onSetMute;

  /// "Keep data": host this account's posts and media ON THIS DEVICE — mirrored
  /// into the store we serve to the mesh, and pinned so the storage sweep never
  /// evicts them. Null hides the switch.
  final bool keepData;
  final void Function(bool keep)? onSetKeep;

  /// This is OUR own profile: show an Edit button instead of Follow/Block.
  final bool isSelf;
  final VoidCallback? onEdit;

  /// Hubs / transport nodes this station is reachable through right now (e.g.
  /// ["hub 07d20e92", "hub 9b31cacc"]). Rendered as a compact line under
  /// "First seen"; empty/null hides it.
  final List<String>? reachableVia;

  /// Reticulum devices this user has been seen announcing from, each
  /// {dest, hops, ageSec, online, services, via}. When [showDevices] is true a
  /// "Reticulum devices" section renders: null = still loading, empty = none
  /// heard. Ignored when [showDevices] is false.
  final List<Map<String, dynamic>>? devices;
  final bool showDevices;

  const ProfileView({
    super.key,
    required this.callsign,
    this.npub,
    this.firstSeenMs,
    this.postCount = 0,
    this.posts = const [],
    this.onPostTap,
    this.onMessage,
    this.likeInfo,
    this.onLike,
    this.replyCount,
    this.onReplyPost,
    this.isReposted,
    this.onRepost,
    this.mentionResolver,
    this.onMentionTap,
    this.following = false,
    this.blocked = false,
    this.onSetFollow,
    this.onSetBlock,
    this.displayName,
    this.about,
    this.avatarImage,
    this.bannerImage,
    this.nip05,
    this.website,
    this.lud16,
    this.muted = false,
    this.keepData = false,
    this.onSetKeep,
    this.onSetMute,
    this.isSelf = false,
    this.onEdit,
    this.reachableVia,
    this.devices,
    this.showDevices = false,
  });

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  late bool _following = widget.following;
  late bool _blocked = widget.blocked;
  late bool _muted = widget.muted;
  late bool _keep = widget.keepData;

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

  void _toggleMute() {
    setState(() => _muted = !_muted);
    widget.onSetMute?.call(_muted);
  }

  void _toggleKeep() {
    setState(() => _keep = !_keep);
    widget.onSetKeep?.call(_keep);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_keep
            ? 'Keeping $_name’s posts and media on this device'
            : 'No longer keeping $_name’s data'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final newest = posts.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.displayName?.trim().isNotEmpty == true
              ? widget.displayName!.trim()
              : callsign,
        ),
        actions: [
          if (!widget.isSelf &&
              (widget.onSetBlock != null ||
                  widget.onSetMute != null ||
                  widget.onSetKeep != null))
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'block') _toggleBlock();
                if (v == 'mute') _toggleMute();
                if (v == 'keep') _toggleKeep();
              },
              itemBuilder: (_) => [
                // "Keep data": this device is its own NOSTR relay and Blossom
                // server, so hosting an account's posts and pictures here is a
                // real thing a user can choose. On = mirror their notes into the
                // store we serve, and PIN their media so the storage sweep can
                // never evict it.
                if (widget.onSetKeep != null)
                  PopupMenuItem(
                    value: 'keep',
                    child: Row(
                      children: [
                        Icon(
                          _keep ? Icons.download_done : Icons.save_alt,
                          size: 18,
                          color: _keep ? Colors.green : null,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('Keep data')),
                        const SizedBox(width: 8),
                        // A switch, not a verb: this is a state the user is
                        // reading as much as an action they are taking.
                        Switch.adaptive(
                          value: _keep,
                          onChanged: (_) {
                            Navigator.of(context).pop();
                            _toggleKeep();
                          },
                        ),
                      ],
                    ),
                  ),
                if (widget.onSetMute != null)
                  PopupMenuItem(
                    value: 'mute',
                    child: Row(
                      children: [
                        Icon(
                          _muted
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_off_outlined,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        // Just the verb. The menu is opened FROM the person's
                        // profile, with their name in the app bar — repeating it
                        // in every item (let alone as a raw pubkey, which is what
                        // this used to do) says nothing the screen has not said.
                        Text(_muted ? 'Unmute' : 'Mute'),
                      ],
                    ),
                  ),
                if (widget.onSetBlock != null)
                  PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(
                          _blocked ? Icons.check_circle_outline : Icons.block,
                          size: 18,
                          color: _blocked ? null : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _blocked ? 'Unblock' : 'Block',
                          style: TextStyle(color: _blocked ? null : Colors.red),
                        ),
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
              if (widget.bannerImage != null)
                Image(
                  image: widget.bannerImage!,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              _header(context, cs),
              Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
              if (widget.showDevices) ...[
                _devicesSection(cs),
                Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
              ],
              if (newest.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No posts from $callsign yet.',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
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

  // ── Reticulum devices ──────────────────────────────────────────────
  static String _relAge(int sec) {
    if (sec < 60) return 'just now';
    if (sec < 3600) return '${sec ~/ 60}m ago';
    if (sec < 86400) return '${sec ~/ 3600}h ago';
    return '${sec ~/ 86400}d ago';
  }

  Widget _devicesSection(ColorScheme cs) {
    final devices = widget.devices;
    Widget body;
    if (devices == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Looking for devices on the network…',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      );
    } else if (devices.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text(
          'No devices seen on the Reticulum network yet.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      );
    } else {
      final onlineN = devices.where((d) => d['online'] == true).length;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '$onlineN of ${devices.length} online',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
          for (final d in devices) _deviceRow(cs, d),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(
            'Reticulum devices',
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        body,
      ],
    );
  }

  Widget _deviceRow(ColorScheme cs, Map<String, dynamic> d) {
    final online = d['online'] == true;
    final dest = (d['dest'] ?? '').toString();
    final shortDest = dest.length > 12 ? '${dest.substring(0, 12)}…' : dest;
    final hops = (d['hops'] is int) ? d['hops'] as int : 0;
    final ageSec = (d['ageSec'] is int) ? d['ageSec'] as int : 0;
    final services = (d['services'] ?? '').toString();
    final status = online ? 'online' : 'last seen ${_relAge(ageSec)}';
    final detail = [
      if (hops > 0) '$hops hop${hops == 1 ? '' : 's'}',
      if (services.isNotEmpty) services,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: online
                  ? const Color(0xFF4CAF50)
                  : cs.onSurfaceVariant.withAlpha(90),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.devices_other, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortDest,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
              color: online ? const Color(0xFF4CAF50) : cs.onSurfaceVariant,
              fontSize: 12,
              fontWeight: online ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
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
                    Text(
                      _name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // The raw pubkey is NOT shown here. It used to be — as a
                    // 12-hex "callsign" that wrapped onto two lines under a
                    // person's name and told the reader nothing they could use.
                    // The npub below is the identity that matters, and it gets a
                    // row of its own rather than being crushed between the name
                    // and the buttons.
                    if (_name != callsign && !_looksLikeHexId(callsign))
                      Text(
                        callsign,
                        style: TextStyle(
                          color: Colors.white.withAlpha(140),
                          fontSize: 13,
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
          // The npub, on a line of its own and in one piece.
          //
          // It used to sit in the narrow column between the avatar and the
          // Follow/Message buttons, where a 63-character identifier had about
          // four centimetres to live in — so it wrapped mid-string and read as
          // broken. It is the account's real name on this network: give it the
          // width, keep it to one line, and make the copy affordance obvious.
          if (npub != null) ...[
            const SizedBox(height: 10),
            _npubRow(context, cs),
          ],
          if (_about.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              activityFormatMentions(_about, widget.mentionResolver),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ],
          if (widget.nip05?.trim().isNotEmpty == true)
            _metaRow(cs, Icons.verified_outlined, widget.nip05!.trim()),
          if (widget.website?.trim().isNotEmpty == true)
            _metaRow(
              cs,
              Icons.link,
              widget.website!.trim(),
              link: true,
              color: cs.primary,
            ),
          if (widget.lud16?.trim().isNotEmpty == true)
            _metaRow(
              cs,
              Icons.bolt,
              widget.lud16!.trim(),
              color: const Color(0xFFF7931A),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(
                'First seen ${_firstSeen()}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              ),
              const SizedBox(width: 16),
              Text(
                '$postCount ${postCount == 1 ? 'post' : 'posts'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          if ((widget.reachableVia ?? const []).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lan_outlined,
                    size: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'Reachable via ${widget.reachableVia!.join(', ')}',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_blocked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.block, size: 14, color: Colors.red),
                  const SizedBox(width: 5),
                  Text(
                    'Blocked — their messages are hidden',
                    style: TextStyle(
                      color: Colors.red.withAlpha(200),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _metaRow(
    ColorScheme cs,
    IconData icon,
    String text, {
    bool link = false,
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Row(
          children: [
            Icon(icon, size: 15, color: color ?? cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color ?? Colors.white.withAlpha(200),
                  fontSize: 13,
                  decoration: link
                      ? TextDecoration.underline
                      : TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: const Text('Follow'),
    );
  }

  String _firstSeen() {
    final ms = firstSeenMs;
    if (ms == null || ms == 0) return 'unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// A pubkey the UI is showing as if it were a name — 12 hex characters, no
  /// meaning to a reader. NOSTR accounts have no callsign, so the host fills the
  /// field with a short pubkey; on a profile that already shows the person's
  /// name, printing it is noise.
  static bool _looksLikeHexId(String s) =>
      s.length >= 8 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

  Widget _npubRow(BuildContext context, ColorScheme cs) {
    final value = npub!;
    return Material(
      color: Colors.white.withAlpha(12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('npub copied'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.key_outlined, size: 15, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  // Ellipsize in the MIDDLE: the ends of an npub are what a
                  // person compares when they check they have the right one.
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    color: cs.primary,
                    fontSize: 12.5,
                    fontFamily: 'RobotoMono',
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.copy_rounded,
                  size: 14, color: Colors.white.withAlpha(120)),
            ],
          ),
        ),
      ),
    );
  }

  /// When a post was written — with the DATE, not just a clock.
  ///
  /// The profile used to print "18:40" and nothing else, so a stream of posts
  /// spanning weeks looked like a single evening: every row said a time, none of
  /// them said which day. Today and yesterday are named (a date there is noise);
  /// anything older carries its date, and a post from another year carries the
  /// year too.
  String _postStamp(Map<String, dynamic> p) {
    final t = (p['t'] as num?)?.toInt() ?? 0;
    final clock = (p['time'] ?? '').toString();
    if (t <= 0) return clock; // no epoch — the wapp's clock string is all we have

    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final now = DateTime.now();
    final hhmm = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';

    final day = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    if (days == 0) return hhmm;
    if (days == 1) return 'Yesterday $hhmm';

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${dt.day} ${months[dt.month - 1]}'
        '${dt.year == now.year ? '' : ' ${dt.year}'}';
    return '$date · $hhmm';
  }

  Widget _postRow(ColorScheme cs, Map<String, dynamic> p) {
    final raw = (p['text'] ?? '').toString();
    final time = _postStamp(p);
    final via = (p['via'] ?? '').toString();
    final convo = (p['convo'] ?? '').toString();
    final mid = (p['mid'] ?? '').toString();
    final body = activityFormatMentions(
      _stripTokens(raw),
      widget.mentionResolver,
    );
    final refs = MediaRef.findAll(raw);
    final tappable =
        widget.onPostTap != null && (convo.isNotEmpty || mid.isNotEmpty);
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
                    Text(
                      time,
                      style: TextStyle(
                        color: Colors.white.withAlpha(120),
                        fontSize: 12,
                      ),
                    ),
                  if (via.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _viaChip(via),
                  ],
                ],
              ),
            if (body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  body,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
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
                        ref: r,
                        size: mediaSizeHint(raw),
                        from: callsign,
                      ),
                  ],
                ),
              ),
            if (mid.isNotEmpty) _postActions(cs, mid, p),
          ],
        ),
      ),
    );
  }

  /// Like / Reply / Retweet under each publication (mirrors the feed).
  Widget _postActions(ColorScheme cs, String mid, Map<String, dynamic> p) {
    final like = widget.likeInfo?.call(mid) ?? (count: 0, mine: false);
    final replies = widget.replyCount?.call(mid) ?? 0;
    final reposted = widget.isReposted?.call(mid) ?? false;
    const muted = Color(0xFF8899A6);

    Widget act(
      IconData icon,
      String? label,
      Color color,
      VoidCallback? onTap,
    ) => InkWell(
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

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          act(
            Icons.chat_bubble_outline,
            replies > 0 ? '$replies' : null,
            muted,
            widget.onReplyPost == null ? null : () => widget.onReplyPost!(p),
          ),
          const SizedBox(width: 18),
          act(
            Icons.repeat,
            null,
            reposted ? const Color(0xFF00BA7C) : muted,
            widget.onRepost == null ? null : () => widget.onRepost!(p),
          ),
          const SizedBox(width: 18),
          act(
            like.mine ? Icons.favorite : Icons.favorite_border,
            like.count > 0 ? '${like.count}' : null,
            like.mine ? Colors.pink : muted,
            widget.onLike == null
                ? null
                : () => widget.onLike!(mid, !like.mine),
          ),
        ],
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
      child: Text(
        via.toUpperCase(),
        style: TextStyle(color: c, fontSize: 8.5, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _avatar(String call, double radius) {
    // A real avatar image (from the profile's kind-0 "picture") wins; otherwise
    // the same deterministic identicon used in the Messages list.
    if (widget.avatarImage != null) {
      return CircleAvatar(radius: radius, backgroundImage: widget.avatarImage);
    }
    return GeneratedAvatar(seed: call, size: radius * 2);
  }

  static String _stripTokens(String s) => stripNoteTokens(s);
}
