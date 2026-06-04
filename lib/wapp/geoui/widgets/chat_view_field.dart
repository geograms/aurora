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

  const ChatViewField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.messages,
    required this.onSend,
    this.tip,
    this.hint = 'Message…',
    this.fill = false,
  });

  @override
  State<ChatViewField> createState() => _ChatViewFieldState();
}

class _ChatViewFieldState extends State<ChatViewField> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

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
    widget.onSend(text);
    _input.clear();
    // Sending always jumps to the latest so the user sees their own message.
    _atBottom = true;
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

  Widget _bubble(Map<String, dynamic> m) {
    final outgoing = (m['dir']?.toString() ?? 'in') == 'out';
    final from = m['from']?.toString() ?? '';
    final text = m['text']?.toString() ?? '';
    final time = m['time']?.toString() ?? '';
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
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
            if (!outgoing && from.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  from,
                  style: const TextStyle(
                      color: Color(0xFF7FB0E0),
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            if (time.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  time,
                  style: TextStyle(
                      color: Colors.white.withAlpha(115), fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composeBar(ColorScheme cs) {
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
