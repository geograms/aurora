// ConversationsField — a generic, app-agnostic messenger primitive: a
// conversation list plus a per-conversation chat view. It renders a
// ConversationStore the wapp owns and reports user intent back through
// callbacks; it has no domain knowledge (no groups, callsigns, bulletins,
// distances — the wapp supplies titles/badges/icons as plain data). Reuses
// ChatViewField for the chat surface (bubbles + composer + scroll-hold).

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../conversation_store.dart';
import 'chat_palette.dart';
import 'chat_view_field.dart';

/// Render a folder/rail icon the way it is actually stored: a built-in control
/// id ("__up"/"__add"/"__edit"/"__access") → a real Material icon; an inline
/// "svg:<xml>" → the SVG; any other non-empty value → it is treated as an emoji/
/// glyph and shown as text; empty → a default folder icon. (The GeoUI icon
/// picker stores emoji or inline SVG, never Material names — so we must not run
/// these through a name→IconData lookup.)
Widget railIconFor(String id, String icon, Color color, {double size = 24}) {
  IconData? mat;
  switch (id) {
    case '__up': mat = Icons.arrow_upward; break;
    case '__add': mat = Icons.add; break;
    case '__edit': mat = Icons.edit_outlined; break;
    case '__access': mat = Icons.lock_outline; break;
  }
  if (mat != null) return Icon(mat, color: color, size: size);
  if (icon.startsWith('svg:')) {
    return SizedBox(
      width: size, height: size,
      child: SvgPicture.string(icon.substring(4), fit: BoxFit.contain),
    );
  }
  if (icon.isNotEmpty) {
    return Text(icon, style: TextStyle(fontSize: size - 2, color: color));
  }
  return Icon(Icons.folder_outlined, color: color, size: size);
}

/// A generic header/room action button the wapp declares (e.g. "new chat").
class ConvAction {
  final String name; // command/event name fired back to the wapp
  final String icon; // generic icon name
  final String tooltip;
  final String label; // menu label (falls back to tooltip)
  const ConvAction(this.name, this.icon, this.tooltip, {this.label = ''});
}

/// A generic labelled checkbox shown above the composer. The wapp declares it
/// and gives it meaning; the host only tracks its on/off state.
class ComposerToggle {
  final String name;
  final String label;
  final bool value;
  /// Hidden in GLOBAL group rooms (ids ending in '*') — e.g. "Include my
  /// location", which makes a post local and so is meaningless worldwide.
  final bool localOnly;
  const ComposerToggle(this.name, this.label, this.value,
      {this.localOnly = false});
}

/// Map a generic icon name to a Material icon. Names are plain UI hints, not
/// domain concepts.
IconData convIcon(String name) {
  switch (name) {
    case 'person':
      return Icons.person;
    case 'group':
      return Icons.groups;
    case 'campaign':
      return Icons.campaign;
    case 'tag':
      return Icons.tag;
    case 'info':
      return Icons.info_outline;
    case 'warning':
      return Icons.warning_amber;
    case 'public':
      return Icons.public;
    case 'add':
      return Icons.add;
    case 'edit':
      return Icons.edit_square;
    case 'repeat':
      return Icons.repeat;
    case 'lock':
      return Icons.lock;
    case 'lock_outline':
      return Icons.lock_outline;
    case 'delete':
      return Icons.delete_outline;
    case 'people':
      return Icons.groups_2_outlined;
    case 'share':
      return Icons.ios_share;
    case 'qr':
    case 'qr_code':
      return Icons.qr_code_2;
    case 'settings':
      return Icons.settings_outlined;
    case 'tune':
      return Icons.tune;
    case 'person_add':
      return Icons.person_add_alt;
    case 'folder':
      return Icons.folder_outlined;
    default:
      return Icons.chat_bubble_outline;
  }
}

Color _hashColor(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.5, 0.55).toColor();
}

class ConversationsField extends StatefulWidget {
  final ConversationStore store;
  final String title;
  final List<ConvAction> listActions;
  final List<ConvAction> roomActions;

  /// A conversation row was opened (host tracks selection; wapp may clear
  /// unread).
  final ValueChanged<String> onSelect;

  /// Send composed text in conversation [id].
  final void Function(String id, String text) onSend;

  /// A header/room action fired; [openId] is the currently open conversation
  /// (empty if none).
  final void Function(String name, String openId) onAction;

  /// Long-press message actions (purely local on the host). Forward gives the
  /// conversation id + the whole message; hide gives id + the message key;
  /// block gives the sender callsign. Null disables that menu entry.
  final void Function(String id, Map<String, dynamic> m)? onForward;
  final void Function(String id, String key)? onHide;
  final void Function(String from)? onBlock;

  /// Per-conversation "…" menu actions. Mute toggles app-wide attention for the
  /// row; Close removes it from the list. Null disables the menu.
  final void Function(String id, bool muted)? onMute;
  final void Function(String id)? onClose;

  /// Labelled checkboxes shown above the composer; toggling reports back.
  final List<ComposerToggle> toggles;
  final void Function(String name, bool value) onToggle;

  /// Tapping a message's location meta (when it carries lat/lon).
  final void Function(Map<String, dynamic>)? onLocate;

  /// Tapping a sender's name on an incoming bubble (e.g. open their profile).
  final void Function(String from)? onSenderTap;

  /// Attach a file to the open conversation — returns a `file:<sha>.<ext>`
  /// token to insert into the composer (host archives + advertises it).
  final Future<String?> Function()? onAttach;

  /// Controlled mode: the host owns which conversation is open (so it can put
  /// the thread title + back arrow in its own AppBar). When [onOpenChanged]
  /// is non-null, [openId] is the source of truth; otherwise the widget keeps
  /// its own internal selection (legacy behaviour).
  final String? openId;
  final ValueChanged<String?>? onOpenChanged;

  /// When false the narrow-layout room view skips its internal header (back
  /// arrow + title) because the host shows that chrome in the AppBar. The
  /// wide (side-by-side) layout always keeps the header.
  final bool showRoomHeader;

  /// Optional left rail shown inside an open conversation — e.g. a circle's
  /// sub-folders. Each item: {id, name, icon}. Tapping fires [onRoomRailTap].
  final List<Map<String, dynamic>> roomRail;
  final void Function(String id)? onRoomRailTap;

  const ConversationsField({
    super.key,
    required this.store,
    required this.onSelect,
    required this.onSend,
    required this.onAction,
    required this.onToggle,
    this.onForward,
    this.onHide,
    this.onBlock,
    this.onMute,
    this.onClose,
    this.title = 'Conversations',
    this.listActions = const [],
    this.roomActions = const [],
    this.toggles = const [],
    this.onLocate,
    this.onSenderTap,
    this.onAttach,
    this.openId,
    this.onOpenChanged,
    this.showRoomHeader = true,
    this.roomRail = const [],
    this.onRoomRailTap,
  });

  @override
  State<ConversationsField> createState() => _ConversationsFieldState();
}

class _ConversationsFieldState extends State<ConversationsField> {
  String? _internalOpenId;

  /// Effective open conversation: host-owned in controlled mode, else local.
  String? get _openId =>
      widget.onOpenChanged != null ? widget.openId : _internalOpenId;

  void _setOpen(String? id) {
    if (widget.onOpenChanged != null) {
      widget.onOpenChanged!(id);
    } else {
      setState(() => _internalOpenId = id);
    }
  }

  void _select(String id) {
    _setOpen(id);
    widget.store.openId = id;
    widget.store.clearUnread(id);
    widget.onSelect(id);
  }

  @override
  Widget build(BuildContext context) {
    // Ignore a selection that no longer exists (don't mutate host state from
    // build — just render the list until the host catches up).
    final openId = (_openId != null && widget.store.items.containsKey(_openId))
        ? _openId
        : null;
    // Keep the store's notion of the open conversation in sync so it can
    // auto-manage unread counts when new messages arrive.
    widget.store.openId = openId;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 320, child: _list(context, wide: true)),
              const VerticalDivider(width: 1),
              Expanded(
                child: openId != null
                    ? _room(context, openId, wide: true)
                    : _emptyRoom(context),
              ),
            ],
          );
        }
        return openId != null
            ? _room(context, openId, wide: false)
            : _list(context, wide: false);
      },
    );
  }

  // ── list ───────────────────────────────────────────────────────────
  Widget _list(BuildContext context, {required bool wide}) {
    final items = widget.store.ordered();
    return Container(
      color: ChatPalette.windowBg,
      child: Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(
            children: [
              // The narrow (phone) layout already shows the screen name in the
              // app bar tab, so the in-list title would just repeat it — only
              // show it in the wide side-by-side layout where the list is its
              // own column.
              if (wide)
                Text(widget.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              for (final a in widget.listActions)
                IconButton(
                  tooltip: a.tooltip,
                  icon: Icon(convIcon(a.icon), size: 22),
                  color: ChatPalette.accent,
                  onPressed: () => widget.onAction(a.name, _openId ?? ''),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? _empty(context)
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) => _tile(context, items[i]),
                ),
        ),
      ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined,
                size: 48, color: cs.onSurfaceVariant.withAlpha(120)),
            const SizedBox(height: 12),
            Text('No conversations yet',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15)),
          ],
        ),
      ),
    );
  }

  Widget _avatar(ConversationItem it, double size) {
    final generic = it.icon != 'person' && it.icon != 'chat';
    if (generic) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: const Color(0xFF5A8F7B),
        child: Icon(convIcon(it.icon), color: Colors.white, size: size * 0.5),
      );
    }
    final color = _hashColor(it.id);
    final letter = it.title.isNotEmpty ? it.title[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withAlpha(60),
      child: Text(letter,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w700, fontSize: size * 0.4)),
    );
  }

  Widget _tile(BuildContext context, ConversationItem it) {
    final cs = Theme.of(context).colorScheme;
    final selected = it.id == _openId;
    return Material(
      color: selected ? ChatPalette.outBubble : Colors.transparent,
      child: InkWell(
        onTap: () => _select(it.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _avatar(it, 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(it.title.isEmpty ? it.id : it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: ChatPalette.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            it.subtitle.isEmpty ? 'No messages yet' : it.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: selected
                                    ? Colors.white70
                                    : ChatPalette.secondary,
                                fontSize: 12.5),
                          ),
                        ),
                        if (it.badge.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(it.badge,
                                style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : ChatPalette.accent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        if (it.private)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.lock,
                                size: 13, color: ChatPalette.accent),
                          ),
                        if (it.muted)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(Icons.notifications_off,
                                size: 14, color: cs.onSurfaceVariant),
                          ),
                        if (it.unread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                // Muted rows show a grey count (no attention).
                                color: it.muted
                                    ? ChatPalette.secondary
                                    : ChatPalette.accent,
                                borderRadius: BorderRadius.circular(10)),
                            child: Text('${it.unread}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.onMute != null ||
                  widget.onClose != null ||
                  widget.roomActions.isNotEmpty)
                _convMenu(context, it),
            ],
          ),
        ),
      ),
    );
  }

  /// The per-conversation "…" menu — the wapp's room actions (e.g. Edit, People,
  /// Share) followed by the built-in Mute/Unmute and Close.
  Widget _convMenu(BuildContext context, ConversationItem it) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: 'Options',
      onSelected: (v) {
        if (v == 'mute') {
          widget.onMute?.call(it.id, !it.muted);
        } else if (v == 'close') {
          widget.onClose?.call(it.id);
        } else if (v.startsWith('action:')) {
          widget.onAction(v.substring(7), it.id);
        }
      },
      itemBuilder: (_) => [
        for (final a in widget.roomActions)
          PopupMenuItem(
            value: 'action:${a.name}',
            child: Row(
              children: [
                Icon(convIcon(a.icon)),
                const SizedBox(width: 10),
                Text(a.label.isNotEmpty ? a.label : a.tooltip),
              ],
            ),
          ),
        if (widget.roomActions.isNotEmpty &&
            (widget.onMute != null || widget.onClose != null))
          const PopupMenuDivider(),
        if (widget.onMute != null)
          PopupMenuItem(
            value: 'mute',
            child: Row(
              children: [
                Icon(it.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined),
                const SizedBox(width: 10),
                Text(it.muted ? 'Unmute' : 'Mute'),
              ],
            ),
          ),
        if (widget.onClose != null)
          const PopupMenuItem(
            value: 'close',
            child: Row(
              children: [
                Icon(Icons.close),
                SizedBox(width: 10),
                Text('Close'),
              ],
            ),
          ),
      ],
    );
  }

  // ── room ───────────────────────────────────────────────────────────
  Widget _room(BuildContext context, String id, {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    final it = widget.store.items[id];
    if (it == null) return _emptyRoom(context);

    final content = Column(
      children: [
        // Narrow + host-chrome: the AppBar shows the back arrow + title, so
        // skip the internal header entirely (one back arrow per screen).
        if (wide || widget.showRoomHeader)
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          decoration: BoxDecoration(
            color: ChatPalette.windowBg,
            border: Border(
                bottom: BorderSide(color: cs.outlineVariant.withAlpha(80))),
          ),
          child: Row(
            children: [
              if (!wide)
                IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => _setOpen(null))
              else
                const SizedBox(width: 6),
              _avatar(it, 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(it.title.isEmpty ? it.id : it.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15)),
                        ),
                        if (it.private)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.lock,
                                size: 14, color: ChatPalette.accent),
                          ),
                      ],
                    ),
                    if (it.private)
                      const Text('Reticulum only',
                          style: TextStyle(
                              color: ChatPalette.accent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600))
                    else if (it.badge.isNotEmpty)
                      Text(it.badge,
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 11.5)),
                  ],
                ),
              ),
              // Room actions live in each conversation's "…" menu (with
              // Mute/Close), not as header icons.
            ],
          ),
        ),
        Expanded(
          child: ChatViewField(
            key: ValueKey('conv_$id'),
            fieldName: 'conv',
            label: '',
            messages: it.messages,
            fill: true,
            composerAccessory: _toggleBar(context, id),
            onLocate: widget.onLocate,
            onSenderTap: widget.onSenderTap,
            onAttach: widget.onAttach,
            onSend: (text) => widget.onSend(id, text),
            onForward: widget.onForward == null
                ? null
                : (m) => widget.onForward!(id, m),
            onHide: widget.onHide == null
                ? null
                : (m) => widget.onHide!(id, (m['key'] ?? '').toString()),
            onBlock: widget.onBlock == null
                ? null
                : (m) => widget.onBlock!((m['from'] ?? '').toString()),
          ),
        ),
      ],
    );
    if (widget.roomRail.isEmpty) return content;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _roomRail(context),
        const VerticalDivider(width: 1),
        Expanded(child: content),
      ],
    );
  }

  /// The sub-folder rail shown on the left of an open conversation.
  Widget _roomRail(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 84,
      color: cs.surfaceContainerHigh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final it in widget.roomRail)
            _roomRailItem(cs, (it['id'] ?? '').toString(),
                (it['name'] ?? '').toString(), (it['icon'] ?? '').toString()),
        ],
      ),
    );
  }

  Widget _roomRailItem(ColorScheme cs, String id, String name, String icon) {
    return InkWell(
      onTap: () => widget.onRoomRailTap?.call(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          children: [
            railIconFor(id, icon, cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget? _toggleBar(BuildContext context, String openId) {
    final cs = Theme.of(context).colorScheme;
    // In a GLOBAL group room (#NAME*), drop local-only toggles (location).
    final isGlobalGroup = openId.startsWith('#') && openId.endsWith('*');
    final shown = [
      for (final t in widget.toggles)
        if (!(isGlobalGroup && t.localOnly)) t
    ];
    if (shown.isEmpty) return null;
    return Align(
      alignment: Alignment.centerLeft,   // keep the toggles on the left edge
      child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
      child: Wrap(
        spacing: 4,
        children: [
          for (final t in shown)
            InkWell(
              onTap: () => widget.onToggle(t.name, !t.value),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      t.value ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 18,
                      color: t.value ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(t.label,
                        style:
                            TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _emptyRoom(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 48, color: cs.onSurfaceVariant.withAlpha(110)),
          const SizedBox(height: 12),
          Text('Select a conversation',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
        ],
      ),
    );
  }
}
