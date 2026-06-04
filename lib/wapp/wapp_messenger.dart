// Telegram/WhatsApp-style Messenger for the APRS wapp — a conversation
// list plus a per-conversation chat view, driven by the grouped
// _msgConvos state on _WappPageState. Conversations are keyed by id:
// a callsign for 1:1 direct messages, or "#GROUP" for an APRS bulletin
// room. Part of the wapp_page library: the builders are an extension on
// _WappPageState (which holds the conversation state fields); the chat
// surface reuses ChatViewField (bubbles + compose + scroll-hold).

part of 'wapp_page.dart';

/// Stable per-callsign avatar colour (hash → hue).
Color _msgAvatarColor(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.5, 0.55).toColor();
}

/// Great-circle distance in km.
double _msgHaversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180.0;
  final dLon = (lon2 - lon1) * pi / 180.0;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

String _msgFmtDistance(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

/// Suggested bulletin group names. APRS bulletin groups are at most 5 chars
/// (addressee is "BLN" + a line id + up to 5 group chars). The first row is
/// the user's general-purpose set; the rest are common ham-radio groups.
/// Users can also add their own (see _msgAddGroupDialog).
const List<String> _kAprsGroups = [
  'ALL', 'MISC', 'TECH', 'FUN', 'WARN', 'INFO', 'NEWS', 'TRADE',
  'WX', 'EMCOM', 'ARES', 'NET', 'DX', 'EVENT', 'HELP', 'SOS',
];

/// Normalise a group name to a valid APRS bulletin group: uppercase,
/// alphanumeric only, max 5 chars. Returns "" if nothing usable remains.
String _msgNormGroup(String raw) {
  var g = raw.trim().toUpperCase();
  if (g.startsWith('#')) g = g.substring(1);
  g = g.replaceAll(RegExp('[^A-Z0-9]'), '');
  return g.length > 5 ? g.substring(0, 5) : g;
}

extension _WappMessenger on _WappPageState {
  bool _convoIsGroup(String convo) => convo.startsWith('#');

  /// Append one incoming/outgoing message to its conversation (called from
  /// _drainOutbox for the "messages" field).
  void _msgAdd(Map<String, dynamic> m) {
    final convo = (m['convo'] ?? '').toString();
    if (convo.isEmpty) return;
    final list = _msgConvos.putIfAbsent(convo, () => <Map<String, dynamic>>[]);
    list.add(m);
    if (list.length > 500) list.removeRange(0, list.length - 500);
    _msgOrder.remove(convo);
    _msgOrder.insert(0, convo);
    if (convo != _msgOpenConvo && (m['dir'] ?? '') != 'out') {
      _msgUnread[convo] = (_msgUnread[convo] ?? 0) + 1;
    }
  }

  /// Open (or create) a conversation and clear its unread count.
  void _msgOpen(String convo) {
    setState(() {
      _msgConvos.putIfAbsent(convo, () => <Map<String, dynamic>>[]);
      if (!_msgOrder.contains(convo)) _msgOrder.insert(0, convo);
      _msgOpenConvo = convo;
      _msgUnread.remove(convo);
    });
  }

  void _msgSend(String convo, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    // The wapp reads `recipient` + `messages_input` from the bundled fields
    // and echoes the message back via chat_append → _msgAdd.
    _fieldValues['recipient'] = convo;
    _fieldValues['messages_input'] = t;
    _sendCommand('messages_send');
  }

  /// Distance from my station to a direct partner's last-known position
  /// (looked up in the map markers). Null for groups / unknown positions.
  String? _convoDistance(String convo) {
    if (_convoIsGroup(convo)) return null;
    final mk = _mapMarkers[convo];
    final lat = (mk?['lat'] as num?)?.toDouble();
    final lon = (mk?['lon'] as num?)?.toDouble();
    final myLat = _mapCenterLat, myLon = _mapCenterLon;
    if (lat == null || lon == null || myLat == null || myLon == null) {
      return null;
    }
    return _msgFmtDistance(_msgHaversineKm(myLat, myLon, lat, lon));
  }

  Widget _buildMessengerScreen(GeoUiBlock screen, GeoUiBlock group) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        final open = _msgOpenConvo;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 320, child: _buildConvoList(context, wide: true)),
              const VerticalDivider(width: 1),
              Expanded(
                child: (open != null)
                    ? _buildConvoPane(context, open, wide: true)
                    : _msgEmptyPane(context),
              ),
            ],
          );
        }
        // Narrow: list, or the open conversation full-screen.
        return open != null
            ? _buildConvoPane(context, open, wide: false)
            : _buildConvoList(context, wide: false);
      },
    );
  }

  // ── Conversation list ──────────────────────────────────────────────
  Widget _buildConvoList(BuildContext context, {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    final ids = _msgOrder.where(_msgConvos.containsKey).toList();
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Text('Messages',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (ids.isNotEmpty)
                IconButton(
                  tooltip: 'Clear all conversations',
                  icon: const Icon(Icons.delete_sweep, size: 22),
                  onPressed: _msgConfirmClearAll,
                ),
              IconButton(
                tooltip: 'Add a group',
                icon: const Icon(Icons.add, size: 24),
                color: cs.primary,
                onPressed: _msgAddGroupDialog,
              ),
              IconButton(
                tooltip: 'New message',
                icon: const Icon(Icons.edit_square, size: 22),
                color: cs.primary,
                onPressed: _msgNewMessageDialog,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ids.isEmpty
              ? _msgEmptyList(context)
              : ListView.separated(
                  itemCount: ids.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) => _convoTile(context, ids[i]),
                ),
        ),
      ],
    );
  }

  Widget _msgEmptyList(BuildContext context) {
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
            const SizedBox(height: 6),
            Text(
              'Messages addressed to your callsign and\ngroup bulletins appear here.\nTap ✎ to start one.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: cs.onSurfaceVariant.withAlpha(170), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _convoTile(BuildContext context, String convo) {
    final cs = Theme.of(context).colorScheme;
    final msgs = _msgConvos[convo] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final isGroup = _convoIsGroup(convo);
    final unread = _msgUnread[convo] ?? 0;
    final selected = convo == _msgOpenConvo;

    String preview = '';
    if (last != null) {
      final from = (last['from'] ?? '').toString();
      final text = (last['text'] ?? '').toString();
      final out = (last['dir'] ?? '') == 'out';
      preview = isGroup ? '${out ? "You" : from}: $text' : text;
    }
    final dist = _convoDistance(convo);

    return Material(
      color: selected ? cs.primary.withAlpha(28) : Colors.transparent,
      child: InkWell(
        onTap: () => _msgOpen(convo),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _msgAvatar(convo, 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(convo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                        ),
                        if (last != null)
                          Text((last['time'] ?? '').toString(),
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview.isEmpty ? 'No messages yet' : preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12.5),
                          ),
                        ),
                        if (dist != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(dist,
                                style: TextStyle(
                                    color: cs.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        if (unread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('$unread',
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

  Widget _msgAvatar(String convo, double size) {
    final isGroup = _convoIsGroup(convo);
    if (isGroup) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: const Color(0xFF5A8F7B),
        child: Icon(Icons.campaign, color: Colors.white, size: size * 0.5),
      );
    }
    final color = _msgAvatarColor(convo);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withAlpha(60),
      child: Text(
        convo.isNotEmpty ? convo[0].toUpperCase() : '?',
        style: TextStyle(
            color: color, fontWeight: FontWeight.w700, fontSize: size * 0.4),
      ),
    );
  }

  // ── Conversation pane ──────────────────────────────────────────────
  Widget _buildConvoPane(BuildContext context, String convo,
      {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    final msgs = _msgConvos[convo] ?? const <Map<String, dynamic>>[];
    final dist = _convoDistance(convo);
    final isGroup = _convoIsGroup(convo);

    // For 1:1 chats, drop the redundant sender label on incoming bubbles
    // (the header already names the partner); keep it for group rooms.
    final shown = isGroup
        ? msgs
        : msgs
            .map((m) => {...m, 'from': ''})
            .toList(growable: false);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(80))),
          ),
          child: Row(
            children: [
              if (!wide)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _msgOpenConvo = null),
                )
              else
                const SizedBox(width: 6),
              _msgAvatar(convo, 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(convo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    Text(
                      isGroup
                          ? 'Group bulletin'
                          : (dist != null ? '$dist away' : 'Direct message'),
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Clear this conversation',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _msgConfirmClearConvo(convo),
              ),
            ],
          ),
        ),
        Expanded(
          child: ChatViewField(
            key: ValueKey('convo_$convo'),
            fieldName: 'messages',
            label: '',
            messages: shown,
            fill: true,
            hint: isGroup ? 'Message $convo…' : 'Message…',
            onSend: (text) => _msgSend(convo, text),
          ),
        ),
      ],
    );
  }

  Widget _msgEmptyPane(BuildContext context) {
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

  // ── Actions ────────────────────────────────────────────────────────
  void _msgNewMessageDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'Callsign (N0CALL-9) or #group',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _msgStartFrom(ctx, controller.text),
            ),
            const SizedBox(height: 8),
            Text(
              'A callsign opens a 1:1 chat; #name opens an APRS group bulletin room.',
              style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => _msgStartFrom(ctx, controller.text),
              child: const Text('Open')),
        ],
      ),
    );
  }

  void _msgStartFrom(BuildContext ctx, String raw) {
    final v = raw.trim();
    if (v.isEmpty) return;
    final String convo;
    if (v.startsWith('#')) {
      final g = _msgNormGroup(v);
      if (g.isEmpty) return;
      convo = '#$g';
    } else {
      convo = v.toUpperCase();
    }
    Navigator.pop(ctx);
    _msgOpen(convo);
  }

  /// "+" → pick a preset bulletin group or create a custom one.
  void _msgAddGroupDialog() {
    final custom = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Add a group'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Join an APRS bulletin group. Tap one below, or create your '
                  'own (max 5 letters).',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in _kAprsGroups)
                      ActionChip(
                        avatar: Icon(Icons.campaign,
                            size: 18, color: cs.primary),
                        label: Text('#$g'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _msgOpen('#$g');
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: custom,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 5,
                        decoration: const InputDecoration(
                          hintText: 'Custom group',
                          prefixText: '#',
                          border: OutlineInputBorder(),
                          isDense: true,
                          counterText: '',
                        ),
                        onSubmitted: (_) =>
                            _msgOpenCustomGroup(ctx, custom.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _msgOpenCustomGroup(ctx, custom.text),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
          ],
        );
      },
    );
  }

  void _msgOpenCustomGroup(BuildContext ctx, String raw) {
    final g = _msgNormGroup(raw);
    if (g.isEmpty) return;
    Navigator.pop(ctx);
    _msgOpen('#$g');
  }

  void _msgConfirmClearConvo(String convo) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $convo'),
        content: Text('Delete all messages with $convo?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _msgConvos.remove(convo);
                _msgOrder.remove(convo);
                _msgUnread.remove(convo);
                if (_msgOpenConvo == convo) _msgOpenConvo = null;
              });
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _msgConfirmClearAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all conversations'),
        content: const Text('Delete every message conversation? '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _msgConvos.clear();
                _msgOrder.clear();
                _msgUnread.clear();
                _msgOpenConvo = null;
              });
            },
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}
