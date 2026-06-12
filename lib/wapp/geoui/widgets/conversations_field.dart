// ConversationsField — a generic, app-agnostic messenger primitive: a
// conversation list plus a per-conversation chat view with an optional
// pinned section. It renders a ConversationStore the wapp owns and reports
// user intent back through callbacks; it has no domain knowledge (no groups,
// callsigns, bulletins, distances — the wapp supplies titles/badges/icons as
// plain data and decides what is pinned). Reuses ChatViewField for the chat
// surface (bubbles + composer + scroll-hold).

import 'package:flutter/material.dart';

import '../conversation_store.dart';
import 'chat_view_field.dart';

/// A generic header/room action button the wapp declares (e.g. "new chat").
class ConvAction {
  final String name; // command/event name fired back to the wapp
  final String icon; // generic icon name
  final String tooltip;
  const ConvAction(this.name, this.icon, this.tooltip);
}

/// A generic labelled checkbox shown above the composer. The wapp declares it
/// and gives it meaning; the host only tracks its on/off state.
class ComposerToggle {
  final String name;
  final String label;
  final bool value;
  const ComposerToggle(this.name, this.label, this.value);
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
    case 'delete':
      return Icons.delete_sweep;
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

  /// Dismiss/act on a pinned item.
  final void Function(String id, String key) onPinnedDismiss;

  /// Labelled checkboxes shown above the composer; toggling reports back.
  final List<ComposerToggle> toggles;
  final void Function(String name, bool value) onToggle;

  /// Tapping a message's location meta (when it carries lat/lon).
  final void Function(Map<String, dynamic>)? onLocate;

  /// Tapping a sender's name on an incoming bubble (e.g. open their profile).
  final void Function(String from)? onSenderTap;

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

  const ConversationsField({
    super.key,
    required this.store,
    required this.onSelect,
    required this.onSend,
    required this.onAction,
    required this.onPinnedDismiss,
    required this.onToggle,
    this.title = 'Conversations',
    this.listActions = const [],
    this.roomActions = const [],
    this.toggles = const [],
    this.onLocate,
    this.onSenderTap,
    this.openId,
    this.onOpenChanged,
    this.showRoomHeader = true,
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
    final cs = Theme.of(context).colorScheme;
    final items = widget.store.ordered();
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(
            children: [
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
                  color: cs.primary,
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
      color: selected ? cs.primary.withAlpha(28) : Colors.transparent,
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
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            it.subtitle.isEmpty ? 'No messages yet' : it.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12.5),
                          ),
                        ),
                        if (it.badge.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(it.badge,
                                style: TextStyle(
                                    color: cs.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        if (it.unread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: cs.primary,
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
            ],
          ),
        ),
      ),
    );
  }

  // ── room ───────────────────────────────────────────────────────────
  Widget _room(BuildContext context, String id, {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    final it = widget.store.items[id];
    if (it == null) return _emptyRoom(context);
    final pinned = it.pinned.entries.toList();

    return Column(
      children: [
        // Narrow + host-chrome: the AppBar shows the back arrow + title, so
        // skip the internal header entirely (one back arrow per screen).
        if (wide || widget.showRoomHeader)
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          decoration: BoxDecoration(
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
                    Text(it.title.isEmpty ? it.id : it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    if (it.badge.isNotEmpty)
                      Text(it.badge,
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 11.5)),
                  ],
                ),
              ),
              for (final a in widget.roomActions)
                IconButton(
                  tooltip: a.tooltip,
                  icon: Icon(convIcon(a.icon), size: 20),
                  onPressed: () => widget.onAction(a.name, id),
                ),
            ],
          ),
        ),
        if (pinned.isNotEmpty) _pinnedBar(context, id, pinned),
        Expanded(
          child: ChatViewField(
            key: ValueKey('conv_$id'),
            fieldName: 'conv',
            label: '',
            messages: it.messages,
            fill: true,
            composerAccessory: widget.toggles.isEmpty ? null : _toggleBar(context),
            onLocate: widget.onLocate,
            onSenderTap: widget.onSenderTap,
            onSend: (text) => widget.onSend(id, text),
          ),
        ),
      ],
    );
  }

  Widget _toggleBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,   // keep the toggles on the left edge
      child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
      child: Wrap(
        spacing: 4,
        children: [
          for (final t in widget.toggles)
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

  Widget _pinnedBar(BuildContext context, String id,
      List<MapEntry<String, Map<String, dynamic>>> pinned) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.primary.withAlpha(20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in pinned)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.push_pin, size: 14, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pinnedLine(e.value),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  InkWell(
                    onTap: () => widget.onPinnedDismiss(id, e.key),
                    child: Icon(Icons.close,
                        size: 16, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _pinnedLine(Map<String, dynamic> m) {
    final from = (m['from'] ?? '').toString();
    final text = (m['text'] ?? '').toString();
    final out = (m['dir'] ?? '') == 'out';
    return from.isEmpty || out ? text : '$from: $text';
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
