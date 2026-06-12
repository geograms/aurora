/*
 * ChatViewField — a messenger-style message list + compose bar for the
 * GeoUI renderer, backing the `$type:"chat"` field.
 *
 * The wapp owns the data: the host appends messages to the field's
 * backing `List<Map>` (via `ui.chat.append`) — each entry is
 * `{dir:'in'|'out', from, text, time}` — and rebuilds. This widget only
 * renders bubbles and surfaces a compose box; on send it calls [onSend]
 * with the typed text (the renderer routes that to the wapp as a
 * `<field>_send` action carrying a `<field>_input` value).
 *
 * Colours mirror the reference APRS implementation: outgoing #2B5278,
 * incoming #1E2D3D.
 */

import 'package:flutter/material.dart';

import '../../../util/media_ref.dart';
import 'media_view.dart';

class ChatViewField extends StatefulWidget {
  final String fieldName;
  final String label;
  final String? tip;
  final String hint;

  /// Message list shared with the host. Each entry:
  /// `{dir:'in'|'out', from, text, time}`. Read-only here.
  final List<Map<String, dynamic>> messages;

  /// Fired with the composed text when the user hits send.
  final ValueChanged<String> onSend;

  /// When true the widget fills its parent's bounded height (no min/max
  /// box, no label/tip chrome) — used inside the map's floating overlay.
  final bool fill;

  /// Optional widget rendered just above the compose bar (a generic slot for
  /// composer extras — e.g. host-declared toggles). No semantics here.
  final Widget? composerAccessory;

  /// Tapping a message's meta line calls this with the message map. The host
  /// decides what to do (e.g. show the sender on a map). Only offered when the
  /// message carries `lat`/`lon`.
  final void Function(Map<String, dynamic>)? onLocate;

  /// Tapping a sender's name on an incoming bubble (e.g. open their profile).
  final void Function(String from)? onSenderTap;

  const ChatViewField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.messages,
    required this.onSend,
    this.tip,
    this.hint = 'Message…',
    this.fill = false,
    this.composerAccessory,
    this.onLocate,
    this.onSenderTap,
  });

  @override
  State<ChatViewField> createState() => _ChatViewFieldState();
}

class _ChatViewFieldState extends State<ChatViewField> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

  /// Lookup of message-id -> message, rebuilt each frame, so a reply can show a
  /// quoted snippet of the message it answers (threading). Threading ids are
  /// opaque (the wapp sets `mid`/`parent`); the host only renders the relation.
  final Map<String, Map<String, dynamic>> _byMid = {};

  /// Number of direct replies each message id has (for the "N replies" hint and
  /// to know which messages are thread-openable). Rebuilt each frame.
  final Map<String, int> _replyCount = {};

  /// When non-null, the list shows only one thread (its root id + every reply in
  /// it) — a focused "4chan-style" view. Tapping a threaded message opens it;
  /// the back arrow returns to the full conversation.
  String? _threadRootMid;

  /// The message currently being replied to (null = composing a new message).
  Map<String, dynamic>? _replyingTo;

  /// Whether the view is pinned to the bottom. New messages only auto-scroll
  /// while this is true, so reading back through history isn't interrupted by
  /// incoming traffic. Becomes true again once the user scrolls back down.
  bool _atBottom = true;

  static const _outColor = Color(0xFF2B5278);
  static const _inColor = Color(0xFF1E2D3D);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _atBottom = (pos.maxScrollExtent - pos.pixels) <= 48;
  }

  void _autoScroll() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    _atBottom = true;
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // Reply target: an explicit pick, else — inside a focused thread — the
    // thread itself, so a plain post stays in the thread (4chan style).
    var target = (_replyingTo?['mid'] ?? '').toString();
    if (target.isEmpty && _threadRootMid != null) target = _threadRootMid!;
    // The "+<mid> " marker is what the wapp uses to thread (across APRS-IS/BLE).
    final out = target.isNotEmpty ? '+$target $text' : text;
    widget.onSend(out);
    _input.clear();
    if (_replyingTo != null) setState(() => _replyingTo = null);
    _atBottom = true;
  }

  void _startReply(Map<String, dynamic> m) {
    if ((m['mid'] ?? '').toString().isEmpty) return; // not threadable
    setState(() => _replyingTo = m);
  }

  /// Toggle a like on a message. We send the opaque wire form the wapp expects
  /// (`mid:like` / `mid:unlike`) through the same channel as a message; the
  /// wapp transmits the vote and reports the tally back. You can only like
  /// someone else's message (outgoing ones show the count read-only).
  void _toggleLike(Map<String, dynamic> m) {
    final mid = (m['mid'] ?? '').toString();
    if (mid.isEmpty) return;
    final liked = m['liked'] == true;
    widget.onSend(liked ? '$mid:unlike' : '$mid:like');
  }

  /// Signature verdict badge (APRX). verified=green, forged=red,
  /// unverified=grey (signed but sender key unknown). Nothing for unsigned.
  Widget _authBadge(Map<String, dynamic> m) {
    final a = (m['auth'] ?? '').toString();
    if (a.isEmpty) return const SizedBox.shrink();
    final IconData icon;
    final Color color;
    final String label;
    switch (a) {
      case 'verified':
        icon = Icons.verified_user;
        color = const Color(0xFF4CAF82);
        label = 'verified';
        break;
      case 'bad':
        icon = Icons.gpp_bad;
        color = const Color(0xFFE0607A);
        label = 'forged';
        break;
      default: // unverified
        icon = Icons.shield_outlined;
        color = Colors.white.withAlpha(120);
        label = 'unverified';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 9.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  /// Lock badge (APRX): the message was end-to-end encrypted to/from this peer.
  Widget _encBadge(Map<String, dynamic> m) {
    if (m['enc'] != true) return const SizedBox.shrink();
    const color = Color(0xFF63B0E8);
    return const Padding(
      padding: EdgeInsets.only(left: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock, size: 12, color: color),
        SizedBox(width: 2),
        Text('encrypted',
            style: TextStyle(
                color: color, fontSize: 9.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  static const _likeColor = Color(0xFFE8638F);

  /// Heart + like count for a message. Interactive on others' messages;
  /// read-only (just the count) on our own. Hidden when not threadable.
  Widget _likeButton(Map<String, dynamic> m, {bool big = false}) {
    final mid = (m['mid'] ?? '').toString();
    if (mid.isEmpty) return const SizedBox.shrink();
    final outgoing = (m['dir']?.toString() ?? 'in') == 'out';
    final liked = m['liked'] == true;
    final count = (m['likes'] as num?)?.toInt() ?? 0;
    // Hide entirely on our own messages with no likes yet (nothing to show).
    if (outgoing && count == 0) return const SizedBox.shrink();
    final color = liked ? _likeColor : Colors.white.withAlpha(140);
    final child = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(liked ? Icons.favorite : Icons.favorite_border,
          size: big ? 16 : 13, color: color),
      if (count > 0) ...[
        const SizedBox(width: 3),
        Text('$count',
            style: TextStyle(
                color: color,
                fontSize: big ? 12.5 : 10,
                fontWeight: FontWeight.w600)),
      ],
    ]);
    if (outgoing) {
      return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: child);
    }
    return InkWell(
      onTap: () => _toggleLike(m),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: child,
      ),
    );
  }

  /// Walk up the parent chain to the visible root of a message's thread.
  String _rootMid(Map<String, dynamic> m) {
    var cur = m;
    final seen = <String>{};
    while (true) {
      final p = (cur['parent'] ?? '').toString();
      if (p.isEmpty) break;
      final parent = _byMid[p];
      if (parent == null) break; // parent not loaded → cur is the visible root
      final cmid = (cur['mid'] ?? '').toString();
      if (cmid.isNotEmpty) seen.add(cmid);
      final pmid = (parent['mid'] ?? '').toString();
      if (pmid.isEmpty || seen.contains(pmid)) break; // cycle guard
      cur = parent;
    }
    return (cur['mid'] ?? '').toString();
  }

  /// A message participates in a thread if it replies to something or has replies.
  bool _isThreaded(Map<String, dynamic> m) {
    final mid = (m['mid'] ?? '').toString();
    return (m['parent'] ?? '').toString().isNotEmpty ||
        (mid.isNotEmpty && (_replyCount[mid] ?? 0) > 0);
  }

  void _openThread(Map<String, dynamic> m) {
    final root = _rootMid(m);
    if (root.isEmpty) return;
    setState(() => _threadRootMid = root);
    _atBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
  }

  /// One-line snippet of a message for quoted-reply display.
  String _snippet(Map<String, dynamic> m) {
    final from = (m['from'] ?? '').toString();
    var text = (m['text'] ?? '').toString().replaceAll('\n', ' ');
    if (text.length > 60) text = '${text.substring(0, 60)}…';
    return from.isEmpty ? text : '$from: $text';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final messages = widget.messages;

    if (messages.length != _lastCount) {
      final grew = messages.length > _lastCount;
      _lastCount = messages.length;
      // Only follow new messages when already at the bottom; otherwise hold
      // the current scroll position so history reading isn't disrupted.
      if (grew && _atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
      }
    }

    // Fill mode: fill the parent's bounded height with list + compose,
    // no min/max box or label/tip (used in the map's floating overlay).
    if (widget.fill) {
      return Column(
        children: [
          Expanded(child: _messageList(cs, messages)),
          const Divider(height: 1),
          if (widget.composerAccessory != null) widget.composerAccessory!,
          _composeBar(cs),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          Container(
            constraints: const BoxConstraints(minHeight: 200, maxHeight: 460),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1115),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Column(
              children: [
                Expanded(child: _messageList(cs, messages)),
                const Divider(height: 1),
                if (widget.composerAccessory != null) widget.composerAccessory!,
                _composeBar(cs),
              ],
            ),
          ),
          if (widget.tip != null && widget.tip!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Text(
                widget.tip!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _messageList(ColorScheme cs, List<Map<String, dynamic>> messages) {
    // Rebuild the id->message index + per-message reply counts (threading).
    _byMid.clear();
    _replyCount.clear();
    for (final m in messages) {
      final mid = (m['mid'] ?? '').toString();
      if (mid.isNotEmpty) _byMid[mid] = m;
    }
    for (final m in messages) {
      final p = (m['parent'] ?? '').toString();
      if (p.isNotEmpty) _replyCount[p] = (_replyCount[p] ?? 0) + 1;
    }

    // Focused thread view: the tapped thread shown forum-style — the root
    // message becomes a topic header and the replies stack beneath it.
    final root = _threadRootMid;
    if (root != null) {
      final members = [for (final m in messages) if (_rootMid(m) == root) m];
      if (members.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _threadRootMid = null);
        });
      }
      final op = _byMid[root];
      final replies = [for (final m in members) if ((m['mid'] ?? '') != root) m];
      var totalLikes = 0;
      for (final m in members) {
        totalLikes += (m['likes'] as num?)?.toInt() ?? 0;
      }
      return Column(
        children: [
          op != null
              ? _threadTopic(cs, op, members.length, totalLikes)
              : _threadHeader(cs, members.length),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              itemCount: op != null ? replies.length : members.length,
              itemBuilder: (context, i) => _bubble(
                  op != null ? replies[i] : members[i],
                  inThread: true),
            ),
          ),
        ],
      );
    }

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages yet',
            style: TextStyle(color: Colors.white.withAlpha(90), fontSize: 13)),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      itemCount: messages.length,
      itemBuilder: (context, i) => _bubble(messages[i]),
    );
  }

  /// Forum-style topic header: the thread's root message rendered as the topic,
  /// with a back arrow, the original post in full, and a summary line ("N
  /// messages" + total likes in the thread) plus a like control for the topic.
  Widget _threadTopic(
      ColorScheme cs, Map<String, dynamic> op, int count, int totalLikes) {
    final from = (op['from'] ?? '').toString();
    final text = (op['text'] ?? '').toString();
    final time = (op['time'] ?? '').toString();
    final via = (op['via'] ?? '').toString();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.primary.withAlpha(26),
        border: Border(
            bottom: BorderSide(color: cs.primary.withAlpha(90), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _threadRootMid = null),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 2),
              child: Row(children: [
                Icon(Icons.arrow_back, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text('Back to chat',
                    style: TextStyle(
                        color: cs.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (from.isNotEmpty)
                    Flexible(
                      child: Text(from,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF7FB0E0),
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                    ),
                  if (via.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _viaChip(via),
                  ],
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(time,
                        style: TextStyle(
                            color: Colors.white.withAlpha(120), fontSize: 10)),
                  ],
                  _authBadge(op),
                ]),
                const SizedBox(height: 5),
                Text(text,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.25)),
                const SizedBox(height: 9),
                Row(children: [
                  Icon(Icons.forum_outlined,
                      size: 14, color: Colors.white.withAlpha(160)),
                  const SizedBox(width: 5),
                  Text('$count message${count == 1 ? '' : 's'}',
                      style: TextStyle(
                          color: Colors.white.withAlpha(180),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                  if (totalLikes > 0) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.favorite, size: 12, color: _likeColor),
                    const SizedBox(width: 4),
                    Text('$totalLikes',
                        style: TextStyle(
                            color: _likeColor,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ],
                  const Spacer(),
                  _likeButton(op, big: true),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Header shown above a focused thread, with a back arrow to the full chat.
  Widget _threadHeader(ColorScheme cs, int count) {
    return InkWell(
      onTap: () => setState(() => _threadRootMid = null),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        decoration: BoxDecoration(
          color: cs.primary.withAlpha(22),
          border: Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(60))),
        ),
        child: Row(
          children: [
            Icon(Icons.arrow_back, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Icon(Icons.forum_outlined, size: 15, color: cs.primary),
            const SizedBox(width: 6),
            Text('Thread · $count message${count == 1 ? '' : 's'}',
                style: TextStyle(
                    color: cs.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('Back to chat',
                style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// The message text with media tokens removed (they render as thumbnails);
  /// leftover runs of whitespace collapse so the caption reads naturally.
  static String _textWithoutTokens(String text) => text
      .replaceAll(RegExp(r'file:[A-Za-z0-9_-]{43}\.[a-z0-9]{1,18}'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Widget _bubble(Map<String, dynamic> m, {bool inThread = false}) {
    final outgoing = (m['dir']?.toString() ?? 'in') == 'out';
    final from = m['from']?.toString() ?? '';
    final text = m['text']?.toString() ?? '';
    // APRX §16 media references: render each `file:<sha256>.<ext>` token as a
    // tappable thumbnail and drop the raw token from the visible text.
    final mediaRefs = MediaRef.findAll(text);
    final time = m['time']?.toString() ?? '';
    final via = m['via']?.toString() ?? '';
    final parent = (m['parent'] ?? '').toString();
    final threadable = (m['mid'] ?? '').toString().isNotEmpty;
    final mid = (m['mid'] ?? '').toString();
    final replies = mid.isEmpty ? 0 : (_replyCount[mid] ?? 0);
    // Outside a focused thread, a message that's part of a thread opens it on tap.
    final canOpen = !inThread && _isThreaded(m);
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      constraints: const BoxConstraints(maxWidth: 440),
      decoration: BoxDecoration(
        color: outgoing ? _outColor : _inColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(outgoing ? 14 : 4),
          bottomRight: Radius.circular(outgoing ? 4 : 14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Forum-style thread view: don't re-quote the root on every reply.
          // Nested replies (parent != root) keep their quote for context.
          if (parent.isNotEmpty &&
              !(inThread && parent == _threadRootMid))
            _quotedParent(parent),
          if (!outgoing && (from.isNotEmpty || via.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (from.isNotEmpty)
                    Flexible(
                      // The sender name opens their profile when the host
                      // offers one (onSenderTap).
                      child: InkWell(
                        onTap: widget.onSenderTap == null
                            ? null
                            : () => widget.onSenderTap!(from),
                        borderRadius: BorderRadius.circular(4),
                        child: Text(
                          from,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFF7FB0E0),
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  if (via.isNotEmpty) ...[
                    if (from.isNotEmpty) const SizedBox(width: 6),
                    _viaChip(via),
                  ],
                ],
              ),
            ),
          if (mediaRefs.isEmpty)
            Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 14))
          else ...[
            if (_textWithoutTokens(text).isNotEmpty)
              Text(_textWithoutTokens(text),
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in mediaRefs) MediaThumbnail(ref: r),
                ],
              ),
            ),
          ],
          if ((m['meta']?.toString() ?? '').isNotEmpty)
            _metaLine(m),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (time.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    time,
                    style: TextStyle(
                        color: Colors.white.withAlpha(115), fontSize: 10),
                  ),
                ),
              _encBadge(m),
              _authBadge(m),
              if (threadable) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _startReply(m),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.reply,
                          size: 12, color: Colors.white.withAlpha(140)),
                      const SizedBox(width: 2),
                      Text('Reply',
                          style: TextStyle(
                              color: Colors.white.withAlpha(140), fontSize: 10)),
                    ]),
                  ),
                ),
              ],
              // "N replies" opens the focused thread (only in the full chat).
              if (replies > 0 && !inThread) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => _openThread(m),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.forum_outlined,
                          size: 12, color: const Color(0xFF7FB0E0)),
                      const SizedBox(width: 3),
                      Text('$replies ${replies == 1 ? 'reply' : 'replies'}',
                          style: const TextStyle(
                              color: Color(0xFF7FB0E0),
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ],
              if (threadable) ...[
                const SizedBox(width: 10),
                _likeButton(m),
              ],
            ],
          ),
        ],
      ),
    );
    final align = outgoing ? Alignment.centerRight : Alignment.centerLeft;
    // Tapping a threaded bubble (in the full chat) opens its focused thread; the
    // inner Reply / "N replies" / meta taps still take precedence in their areas.
    if (!canOpen) return Align(alignment: align, child: bubble);
    return Align(
      alignment: align,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openThread(m),
        child: bubble,
      ),
    );
  }

  /// Quoted snippet of the message this one replies to (threading). Shows the
  /// parent's author + text when it's loaded, else just the short reference id.
  Widget _quotedParent(String parentMid) {
    final p = _byMid[parentMid];
    final label = p != null ? _snippet(p) : '#$parentMid';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(6),
        border: Border(
            left: BorderSide(color: const Color(0xFF7FB0E0), width: 2.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.subdirectory_arrow_right,
              size: 12, color: const Color(0xFF7FB0E0).withAlpha(200)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Colors.white.withAlpha(170),
                  fontSize: 11,
                  fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  /// The small meta/distance line under a bubble. When the message carries a
  /// location and a handler is set, it becomes a tappable link.
  Widget _metaLine(Map<String, dynamic> m) {
    final tappable =
        widget.onLocate != null && m['lat'] != null && m['lon'] != null;
    final color = tappable
        ? const Color(0xFF7FB0E0)
        : Colors.white.withAlpha(165);
    final row = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.near_me, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            m['meta'].toString(),
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              decoration: tappable ? TextDecoration.underline : null,
              decorationColor: color,
            ),
          ),
        ],
      ),
    );
    if (!tappable) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => widget.onLocate!(m), child: row),
    );
  }

  /// A small uppercase origin chip ("BLE", "NET", …). The wapp supplies the
  /// label as opaque text; the colour is derived from the string so distinct
  /// transports get distinct, stable colours without any domain knowledge here.
  Widget _viaChip(String via) {
    final color = _viaColor(via);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(130), width: 0.6),
      ),
      child: Text(
        via.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Color _viaColor(String s) {
    var h = 0;
    for (final c in s.toUpperCase().codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, 0.62).toColor();
  }

  Widget _replyBanner(ColorScheme cs) {
    final m = _replyingTo!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: Colors.white.withAlpha(12),
      child: Row(
        children: [
          Icon(Icons.reply, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Replying to ${_snippet(m)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: Colors.white.withAlpha(150),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _composeBar(ColorScheme cs) {
    if (_replyingTo != null) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        _replyBanner(cs),
        _composeRow(cs),
      ]);
    }
    return _composeRow(cs);
  }

  Widget _composeRow(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(color: Colors.white.withAlpha(90)),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withAlpha(15),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.send),
            color: cs.primary,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
