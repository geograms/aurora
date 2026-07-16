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
  final VoidCallback onSettings;
  final void Function(String id) onMemberTap;
  final void Function(String from)? onSenderTap;

  const RoomsField({
    super.key,
    required this.rooms,
    required this.store,
    required this.openId,
    required this.memberSections,
    required this.onOpenRoom,
    required this.onSend,
    required this.onNewRoom,
    required this.onSettings,
    required this.onMemberTap,
    this.onSenderTap,
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
    setState(() => _railW = (_railW + d.delta.dx).clamp(_collapsed, _expanded));
  }

  void _dragEnd(DragEndDetails d) {
    setState(() => _railW = _railExpanded ? _expanded : _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (ctx, c) {
      if (c.maxWidth >= 640) return _wide(cs);
      return _narrow(cs, c.maxWidth);
    });
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
    return Row(children: [
      _railBox(cs),
      const VerticalDivider(width: 1, thickness: 1),
      Expanded(child: _chat(cs)),
      AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: _membersOpen ? 260 : 0,
        child: _membersOpen
            ? Row(children: [
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _members(cs)),
              ])
            : null,
      ),
    ]);
  }

  // Narrow (phone): the chat keeps full width behind a collapsed rail; the
  // expanded rail and the member panel OVERLAY it (Discord-mobile style) with a
  // tap-to-close scrim, so the chat is never squeezed.
  Widget _narrow(ColorScheme cs, double maxW) {
    final panelW = (maxW * 0.82).clamp(220.0, 340.0);
    final drawerOpen = _railW > _collapsed + 4 || _membersOpen;
    return Stack(children: [
      Positioned(
          left: _collapsed, top: 0, right: 0, bottom: 0, child: _chat(cs)),
      if (drawerOpen)
        Positioned(
          left: _collapsed,
          top: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap: () => setState(() {
              _railW = _collapsed;
              _membersOpen = false;
            }),
            child: Container(color: Colors.black.withValues(alpha: 0.45)),
          ),
        ),
      Positioned(left: 0, top: 0, bottom: 0, child: _railBox(cs)),
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
    ]);
  }

  Widget _rail(ColorScheme cs) {
    final expanded = _railExpanded;
    return SafeArea(
      right: false,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final r in widget.rooms) _roomTile(cs, r, expanded),
                _addTile(cs, expanded),
              ],
            ),
          ),
          const Divider(height: 1),
          _gearTile(cs, expanded),
        ],
      ),
    );
  }

  Widget _roomTile(ColorScheme cs, Map<String, dynamic> r, bool expanded) {
    final id = '${r['id'] ?? ''}';
    if (id.isEmpty) return const SizedBox.shrink();
    final name = '${r['name'] ?? id}';
    final depth = (r['depth'] as num?)?.toInt() ?? 0;
    final unread = (r['unread'] as num?)?.toInt() ?? 0;
    final selected = r['selected'] == true || id == widget.openId;
    final icon = _avatar(cs, id, name, selected);
    return InkWell(
      onTap: () => widget.onOpenRoom(id),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            expanded ? 8.0 + depth * 14 : 8, 4, 8, 4),
        child: Row(
          children: [
            icon,
            if (expanded) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? cs.primary : cs.onSurface,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    )),
              ),
            ],
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: cs.primary, borderRadius: BorderRadius.circular(10)),
                child: Text('$unread',
                    style: TextStyle(color: cs.onPrimary, fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(ColorScheme cs, String id, String name, bool selected) {
    final ch = name.isNotEmpty ? name[0].toUpperCase() : '#';
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
      child: Text(ch,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
    );
  }

  Widget _addTile(ColorScheme cs, bool expanded) {
    return InkWell(
      onTap: () => widget.onNewRoom(widget.openId ?? ''),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: cs.surfaceContainerHighest, shape: BoxShape.circle),
            child: Icon(Icons.add, color: cs.primary),
          ),
          if (expanded) ...[
            const SizedBox(width: 10),
            Text('New room', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  Widget _gearTile(ColorScheme cs, bool expanded) {
    return InkWell(
      onTap: widget.onSettings,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(children: [
          Icon(Icons.settings, color: cs.onSurfaceVariant, size: 26),
          if (expanded) ...[
            const SizedBox(width: 12),
            Text('Settings', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  Widget _chat(ColorScheme cs) {
    final open = widget.openId;
    final room = open == null ? null : widget.store.items[open];
    final name = room?.title ?? (open ?? '');
    return Column(
      children: [
        // room header: name + members toggle
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
          ),
          child: Row(children: [
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            IconButton(
              tooltip: 'Members',
              icon: Icon(_membersOpen ? Icons.group : Icons.group_outlined),
              onPressed: () => setState(() => _membersOpen = !_membersOpen),
            ),
          ]),
        ),
        Expanded(
          child: open == null
              ? Center(
                  child: Text('Pick a room',
                      style: TextStyle(color: cs.onSurfaceVariant)))
              : GestureDetector(
                  // swipe left over the chat reveals the member panel
                  onHorizontalDragEnd: (d) {
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
            border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
          ),
          child: Text('Members',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
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
