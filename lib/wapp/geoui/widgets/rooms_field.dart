import 'package:flutter/material.dart';

import '../conversation_store.dart';
import 'chat_view_field.dart';
import 'people_view_field.dart';

/// `$type:"rooms"` — a Discord-like chat layout, driven entirely by the wapp.
///
/// A thin left icon rail of rooms that expands on a left→right drag into a panel
/// of room names + the nested sub-room tree (a `+` creates a room, a bottom gear
/// opens settings); a center chat pane; and a member list that slides in from the
/// right. The widget is app-agnostic: it renders the room list, chat messages and
/// members it is given, and reports taps back. NIP-72 / moderation semantics live
/// in the wapp.
///
/// Data in: `ui.rooms.set {rooms:[{id,name,icon,parent,depth,unread,selected}]}`
/// for the rail, the usual `ui.convo.*` for the open room's messages, and
/// `ui.people.set` (field `room_members`) for the member panel.
class RoomsField extends StatefulWidget {
  /// Rail rooms, pre-ordered (root first, children after their parent).
  final List<Map<String, dynamic>> rooms;

  /// Message store; the open room's messages are `store.items[openId]?.messages`.
  final ConversationStore store;

  /// The selected room id (whose chat is shown), or null.
  final String? openId;

  /// `ui.people.set` sections for the right-side member list.
  final List<Map<String, dynamic>> memberSections;

  final void Function(String id) onOpenRoom;
  final void Function(String id, String text) onSend;
  final void Function(String parentId) onNewRoom;

  /// "New chat" — find a PERSON (NomadNet/LXMF peer, callsign, npub) and start
  /// a direct conversation. Distinct from onNewRoom, which creates a place.
  final VoidCallback? onNewChat;

  /// Search across rooms, channels, conversations and people. The rail only
  /// shows what you are already in; this finds everything else.
  final VoidCallback? onSearch;

  final VoidCallback onSettings;
  final void Function(String id) onMemberTap;
  final void Function(String from)? onSenderTap;

  /// Long-press bubble actions, same contract as the conversations widget:
  /// hide one message (by its content key) / block its sender. The rooms
  /// layout embeds the same chat view, and without these the ONLY layout most
  /// users see had no way to make a spammy sender go away.
  final void Function(String id, String key)? onHide;
  final void Function(String from)? onBlock;

  const RoomsField({
    super.key,
    required this.rooms,
    required this.store,
    required this.openId,
    required this.memberSections,
    required this.onOpenRoom,
    required this.onSend,
    required this.onNewRoom,
    this.onNewChat,
    this.onSearch,
    required this.onSettings,
    required this.onMemberTap,
    this.onSenderTap,
    this.onHide,
    this.onBlock,
  });

  @override
  State<RoomsField> createState() => _RoomsFieldState();
}

class _RoomsFieldState extends State<RoomsField> {
  static const double _collapsed = 64;
  static const double _expanded = 248;
  static const double _threshold = 150;
  double _railW = _collapsed;
  bool _membersOpen = false;

  bool get _railExpanded => _railW > _threshold;

  void _dragUpdate(DragUpdateDetails d) {
    _userSized = true; // the user's width choice outranks the auto sizing
    setState(() => _railW = (_railW + d.delta.dx).clamp(_collapsed, _expanded));
  }

  void _dragEnd(DragEndDetails d) {
    setState(() => _railW = _railExpanded ? _expanded : _collapsed);
  }

  /// Wide layouts open with the rail EXPANDED (names visible); narrow ones
  /// collapse it, because there the rail OVERLAYS the chat and an expanded
  /// one hides the conversation you just opened. Re-evaluated whenever the
  /// width crosses the threshold (a resized desktop window is the same
  /// problem as a phone), but the user's own drag wins from then on.
  bool _userSized = false;
  double? _autoW;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Tell the store which room is on screen, exactly as ConversationsField
    // does. Without it the store believed NOTHING was open, so a message
    // arriving in the very thread the user was reading bumped its unread
    // badge — a "1" sitting on the row you are looking at.
    widget.store.openId = widget.openId;
    final open = widget.openId;
    if (open != null) widget.store.clearUnread(open);
    return LayoutBuilder(
      builder: (ctx, c) {
        if (!_userSized) {
          final want = c.maxWidth >= 900 ? _expanded : _collapsed;
          if (_autoW != want) {
            _autoW = want;
            _railW = want;
          }
        }
        if (c.maxWidth >= 640) return _wide(cs);
        return _narrow(cs, c.maxWidth);
      },
    );
  }

  Widget _railBox(ColorScheme cs) => GestureDetector(
    onHorizontalDragUpdate: _dragUpdate,
    onHorizontalDragEnd: _dragEnd,
    behavior: HitTestBehavior.opaque,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: _railW,
      color: cs.surfaceContainerHigh,
      child: _rail(cs),
    ),
  );

  // Wide (tablet/desktop): all three panes side by side.
  Widget _wide(ColorScheme cs) {
    return Row(
      children: [
        _railBox(cs),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(child: _chat(cs)),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: _membersOpen ? 260 : 0,
          child: _membersOpen
              ? Row(
                  children: [
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: _members(cs)),
                  ],
                )
              : null,
        ),
      ],
    );
  }

  // Narrow (phone): the chat keeps full width behind a collapsed rail; the
  // expanded rail and the member panel OVERLAY it (Discord-mobile style) with a
  // tap-to-close scrim, so the chat is never squeezed.
  // Narrow (phone): the standard list<->detail pattern. No room open — the
  // conversation list fills the screen. A room open — the chat fills the
  // screen, and the ONE back arrow (the wapp AppBar's, wired by the host)
  // returns to the list. The old layout kept a collapsed rail beside the chat
  // and grew a second arrow in the thread header; two stacked back buttons
  // with different meanings helped nobody.
  Widget _narrow(ColorScheme cs, double maxW) {
    final panelW = (maxW * 0.82).clamp(220.0, 340.0);
    if (widget.openId == null) {
      _railW = _expanded; // list fills the screen
      return Material(color: cs.surfaceContainerHigh, child: _rail(cs));
    }
    // Back closes what is on top: the member panel first; with it closed the
    // pop propagates to the host, which closes the room back to the list.
    return PopScope(
      canPop: !_membersOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _membersOpen = false);
      },
      child: Stack(
        children: [
          Positioned.fill(child: _chat(cs)),
          if (_membersOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _membersOpen = false),
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: _membersOpen ? panelW : 0,
              child: _membersOpen
                  ? Material(color: cs.surface, child: _members(cs))
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rail(ColorScheme cs) {
    final expanded = _railExpanded;
    return SafeArea(
      right: false,
      child: Column(
        children: [
          // Search sits at the TOP: it is how you reach anything not already
          // on the rail, so it should not be below a list of arbitrary length.
          if (widget.onSearch != null) _searchTile(cs, expanded),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final r in _byRecency()) _roomTile(cs, r, expanded),
              ],
            ),
          ),
          const Divider(height: 1),
          _gearTile(cs, expanded),
        ],
      ),
    );
  }

  /// Rail rows, most recently active first — the rail's job is to lead with
  /// what you actually use, and it used to render subscription order, so a
  /// conversation you had never opened sat above the one you were in.
  ///
  /// The store is the authority within a session (it stamps `activityTs` on
  /// every message and unread); the wapp's `seen` (epoch seconds, persisted)
  /// carries the order across a restart, when the store's messages are
  /// reloaded but its timestamps are older than the app itself.
  List<Map<String, dynamic>> _byRecency() {
    final rows = [...widget.rooms];
    int rank(Map<String, dynamic> r) {
      final id = '${r['id'] ?? ''}';
      final ts = widget.store.items[id]?.activityTs ?? 0;
      if (ts > 0) return ts;
      final seen = (r['seen'] as num?)?.toInt() ?? 0;
      return seen > 0 ? seen * 1000 : 0; // wapp reports epoch SECONDS
    }

    final idx = {for (var i = 0; i < rows.length; i++) '${rows[i]['id']}': i};
    rows.sort((a, b) {
      final ra = rank(a), rb = rank(b);
      if (ra != rb) return rb.compareTo(ra);
      // Never-touched rows keep their given order (the room tree's shape).
      return (idx['${a['id']}'] ?? 0).compareTo(idx['${b['id']}'] ?? 0);
    });
    return rows;
  }

  /// "2m" / "4h" / "yd" / "3d" — a chat list wants an age, not a clock.
  static String _ago(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays == 1) return 'yd';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }

  Widget _roomTile(ColorScheme cs, Map<String, dynamic> r, bool expanded) {
    final id = '${r['id'] ?? ''}';
    if (id.isEmpty) return const SizedBox.shrink();
    final name = '${r['name'] ?? id}';
    final depth = (r['depth'] as num?)?.toInt() ?? 0;
    // The wapp rarely knows the unread count — the conversation store does
    // (it tracks arrivals against the open room). Fall back to it, so a room
    // or channel with waiting messages actually says so on the rail.
    final unread =
        (r['unread'] as num?)?.toInt() ?? widget.store.items[id]?.unread ?? 0;
    final selected = r['selected'] == true || id == widget.openId;
    final item = widget.store.items[id];
    final live = r['live'] == true;

    // The second line: what was last said here, else what this place IS.
    // "N people seen" is the wapp's count of DISTINCT senders observed — never
    // a membership roster, which neither rooms nor LXMF groups publish.
    // Newest message that is actually a message. A like arrives as a
    // "<mid>:like" vote and is filtered out of the timeline — quoting one as
    // the preview would show a hex blob as the last thing anybody said.
    var lastMsg = '';
    for (final m in (item?.messages ?? const []).reversed) {
      final text = (m['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      if (RegExp(r'^[0-9a-f]{8,64}:(?:un)?like$').hasMatch(text)) continue;
      if (m['sys'] == true) continue;
      final from = (m['from'] ?? '').toString();
      lastMsg = from.isEmpty ? text : '$from: $text';
      break;
    }
    final people = (r['people'] as num?)?.toInt() ?? 0;
    var sub = lastMsg.isNotEmpty
        ? lastMsg
        : (item?.subtitle.isNotEmpty ?? false ? item!.subtitle : '');
    if (sub.isEmpty && people > 0) {
      sub = people == 1 ? '1 person seen' : '$people people seen';
    }
    if (sub.startsWith(': ')) sub = sub.substring(2);

    final ts = item?.activityTs ?? 0;
    final seenSec = (r['seen'] as num?)?.toInt() ?? 0;
    final age = _ago(ts > 0 ? ts : seenSec * 1000);

    var icon = _avatar(cs, id, name, selected);
    // Collapsed rail: there is no row space beside a 44px avatar in a 64px
    // rail, so the count rides ON the avatar as a corner chip (a badge in the
    // row overflowed it). Expanded keeps the inline pill next to the name.
    if (!expanded && unread > 0) {
      icon = Stack(
        clipBehavior: Clip.none,
        children: [
          icon,
          Positioned(
            top: -3,
            right: -3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.surface, width: 1.5),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      );
    }
    final tile = InkWell(
      onTap: () {
        widget.onOpenRoom(id);
        // Narrow: the expanded rail is an overlay ON the chat, so picking a
        // conversation has to get out of the way — otherwise you tap a room
        // and still see the list.
        if (MediaQuery.of(context).size.width < 900 && _railExpanded) {
          setState(() => _railW = _collapsed);
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(expanded ? 8.0 + depth * 14 : 8, 4, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            icon,
            if (expanded) ...[
              const SizedBox(width: 10),
              // Two lines: who, and what was last said. A list of bare names
              // cannot tell an active conversation from a dead one.
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (live) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFF3FB950),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? cs.primary : cs.onSurface,
                              fontWeight: unread > 0 || selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (age.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              age,
                              style: TextStyle(
                                fontSize: 11,
                                color: unread > 0
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: unread > 0
                                ? cs.onSurface
                                : cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (unread > 0)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$unread',
                    style: TextStyle(color: cs.onPrimary, fontSize: 11),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
    // Collapsed: hovering tells the full name (desktop); the abbreviated
    // avatar label already carries the gist.
    return expanded ? tile : Tooltip(message: name, child: tile);
  }

  Widget _avatar(ColorScheme cs, String id, String name, bool selected) {
    // The label is the NAME, abbreviated — never a bare symbol. Channels are
    // called "#DEV (global)": strip the '#' and the scope suffix, keep up to
    // four letters ("DEV", "NEWS", "NOMA"), so a collapsed rail still reads.
    // A rail of identical '#' circles distinguished only by hash-colour was
    // unusable — nobody knows what to click.
    var label = '';
    for (var i = 0; i < name.length && label.length < 4; i++) {
      final ch = name[i];
      if (ch == ' ' || ch == '(') break; // scope tag: not part of the name
      if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) label += ch.toUpperCase();
    }
    if (label.isEmpty) label = name.isNotEmpty ? name[0].toUpperCase() : '#';
    final hue = (id.hashCode & 0xff) / 255.0;
    final bg = HSLColor.fromAHSL(1, hue * 360, 0.5, 0.45).toColor();
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: selected ? Border.all(color: cs.primary, width: 2.5) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: label.length <= 1
              ? 18
              : label.length == 2
              ? 14
              : label.length == 3
              ? 12
              : 10.5,
          letterSpacing: label.length >= 3 ? -0.3 : 0,
        ),
      ),
    );
  }

  Widget _searchTile(ColorScheme cs, bool expanded) {
    final tile = InkWell(
      onTap: widget.onSearch,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: expanded
            ? Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text(
                      'Search',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            : Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.search, color: cs.onSurfaceVariant),
              ),
      ),
    );
    return expanded
        ? tile
        : Tooltip(message: 'Search rooms, chats and people', child: tile);
  }

  Widget _gearTile(ColorScheme cs, bool expanded) {
    return InkWell(
      onTap: widget.onSettings,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.settings, color: cs.onSurfaceVariant, size: 26),
            if (expanded) ...[
              const SizedBox(width: 12),
              Text('Settings', style: TextStyle(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chat(ColorScheme cs) {
    final open = widget.openId;
    final room = open == null ? null : widget.store.items[open];
    // Who you are talking to. The store title is the display name; for a
    // direct LXMF peer also show the address underneath, because a name alone
    // ("Ben Mobile") does not tell you WHICH address you are about to message
    // — and when there is no name yet, the address is the only identity there
    // is. Falling back to the raw conversation id (as this did) shows neither.
    final isLxmf = (open ?? '').startsWith('lxmf:');
    final addr = isLxmf ? open!.substring(5) : '';
    var name = room?.title ?? '';
    if (name.isEmpty) {
      name = isLxmf
          ? 'LXMF ${addr.length > 8 ? addr.substring(0, 8) : addr}'
          : (open ?? '');
    }
    return Column(
      children: [
        // room header: who + members toggle (and, on a narrow window where the
        // rail is hidden behind the chat, the way back to it)
        Container(
          height: 48,
          padding: const EdgeInsets.only(left: 4, right: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant, width: 1),
            ),
          ),
          child: Row(
            children: [
              // No back arrow here: the wapp AppBar's single arrow is the
              // back (the host closes the room on narrow). A second arrow in
              // this header sat directly under it doing something different.
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isLxmf)
                      Text(
                        'NomadNet · $addr',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Members',
                icon: Icon(_membersOpen ? Icons.group : Icons.group_outlined),
                onPressed: () => setState(() => _membersOpen = !_membersOpen),
              ),
            ],
          ),
        ),
        Expanded(
          child: open == null
              ? Center(
                  child: Text(
                    'Pick a room',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                )
              : GestureDetector(
                  // Swipe left over the chat reveals the member panel — but ONLY
                  // on a wide layout. On a phone, Android's own back gesture is
                  // an inward swipe from the screen edge, which arrives here as
                  // exactly this leftward drag: trying to leave a conversation
                  // opened the member list instead, over and over, with no way
                  // out. The header's group button is the way in on narrow.
                  onHorizontalDragEnd: MediaQuery.of(context).size.width < 640
                      ? null
                      : (d) {
                          if ((d.primaryVelocity ?? 0) < -200) {
                            setState(() => _membersOpen = true);
                          } else if ((d.primaryVelocity ?? 0) > 200) {
                            setState(() => _membersOpen = false);
                          }
                        },
                  child: ChatViewField(
                    key: ValueKey('room-$open'),
                    fieldName: 'rooms_chat',
                    label: '',
                    hint: 'Message…',
                    fill: true,
                    safeBottom: true,
                    messages: room?.messages ?? const [],
                    onSend: (t) => widget.onSend(open, t),
                    onSenderTap: widget.onSenderTap,
                    onHide: widget.onHide == null
                        ? null
                        : (m) =>
                              widget.onHide!(open, (m['key'] ?? '').toString()),
                    onBlock: widget.onBlock == null
                        ? null
                        : (m) => widget.onBlock!((m['from'] ?? '').toString()),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _members(ColorScheme cs) {
    return Column(
      children: [
        Container(
          height: 48,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant, width: 1),
            ),
          ),
          child: Text(
            'Members',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: PeopleViewField(
            fieldName: 'room_members',
            sections: widget.memberSections,
            onTap: widget.onMemberTap,
            onAction: (action, id) => widget.onMemberTap(id),
          ),
        ),
      ],
    );
  }
}
