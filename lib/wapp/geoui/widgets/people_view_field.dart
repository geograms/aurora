/* Aurora · GeoUI people list ($type:"people")
 *
 * PeopleViewField — a social-network style people list: segmented sections
 * (e.g. Following | Followers), one row per person with an avatar, title,
 * subtitle, tag chips and a trailing action button (Follow / Following).
 * Completely data-driven: the wapp pushes the content via `ui.people.set`
 * and receives generic field-derived commands back:
 *   <field>_tap     (row tapped;            <field>_id = row id)
 *   <field>_<name>  (trailing button tapped; <field>_id = row id)
 * The host knows nothing about what the rows or actions mean.
 */

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../util/media_ref.dart';
import '../../shared_media_fetch.dart' show resolveSharedMedia;
import '../geoui_renderer.dart' show geoUiResolveIcon;
import 'generated_avatar.dart';
import 'media_view.dart' show sharedMediaArchive;

class PeopleViewField extends StatefulWidget {
  final String fieldName;

  /// Sections as pushed by the wapp: [{title, items:[{id, title, subtitle,
  /// tags:[..], action, actionLabel, actionStyle}]}].
  final List<Map<String, dynamic>> sections;

  /// Row tapped → host forwards `<field>_tap` with `<field>_id`.
  final void Function(String id) onTap;

  /// Trailing button tapped → host forwards `<field>_<action>` with
  /// `<field>_id`.
  final void Function(String action, String id) onAction;

  /// Message shown when the active section has no rows.
  final String? emptyText;

  const PeopleViewField({
    super.key,
    required this.fieldName,
    required this.sections,
    required this.onTap,
    required this.onAction,
    this.emptyText,
  });

  @override
  State<PeopleViewField> createState() => _PeopleViewFieldState();
}

class _PeopleViewFieldState extends State<PeopleViewField> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = widget.sections;
    if (_section >= sections.length) _section = 0;
    final items = sections.isEmpty
        ? const <Map<String, dynamic>>[]
        : ((sections[_section]['items'] as List?) ?? const [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section selector (Following (n) | Followers (n)) — Twitter-style
        // top tabs with an underline on the active one.
        if (sections.length > 1)
          Row(
            children: [
              for (var i = 0; i < sections.length; i++)
                Expanded(child: _sectionTab(cs, sections[i], i)),
            ],
          ),
        if (sections.length > 1) const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? _empty(cs)
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    indent: 72,
                    color: cs.outlineVariant.withAlpha(50),
                  ),
                  itemBuilder: (context, i) => _row(cs, items[i]),
                ),
        ),
      ],
    );
  }

  Widget _sectionTab(ColorScheme cs, Map<String, dynamic> s, int idx) {
    final sel = _section == idx;
    final title = (s['title'] ?? '').toString();
    final count = ((s['items'] as List?) ?? const []).length;
    return InkWell(
      onTap: () => setState(() => _section = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 3,
              color: sel ? cs.primary : Colors.transparent,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          // "Downloaded (3)". A bare trailing number read as part of the title
          // ("Downloaded 3"), and a wapp that wrote its own count into the title
          // ended up saying it twice. The count belongs to the tab, so the tab
          // formats it — and it says (0) rather than hiding, because "none yet"
          // is information the user wants, not a state to conceal.
          '$title ($count)',
          style: TextStyle(
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? cs.onSurface : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _empty(ColorScheme cs) {
    return Center(
      child: Text(
        (widget.emptyText?.isNotEmpty ?? false)
            ? widget.emptyText!
            : 'Nobody here yet.',
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _row(ColorScheme cs, Map<String, dynamic> it) {
    final id = (it['id'] ?? '').toString();
    final title = (it['title'] ?? id).toString();
    final subtitle = (it['subtitle'] ?? '').toString();
    final tags = ((it['tags'] as List?) ?? const [])
        .map((t) => t.toString())
        .where((t) => t.isNotEmpty)
        .toList();
    final action = (it['action'] ?? '').toString();
    final actionLabel = (it['actionLabel'] ?? '').toString();
    final avatar = (it['avatar'] ?? '').toString();
    // "filled" reads as the suggestion (Follow), "outlined" as the current
    // state (Following) — matching the familiar social-app pattern.
    final filled = (it['actionStyle'] ?? 'outlined').toString() == 'filled';
    // Optional per-row overflow ("...") menu: [{label, value}]. Selecting an
    // entry fires onAction(value, id) — same path as the trailing button.
    final menu = ((it['menu'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) => (m['value'] ?? '').toString().isNotEmpty)
        .toList();
    // Optional row of small trailing icon buttons: [{icon, action, tip}].
    // Each fires onAction(action, id) — for compact per-row controls like an
    // edit pencil and a remove (−) button.
    final buttons = ((it['buttons'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) => (m['action'] ?? '').toString().isNotEmpty)
        .toList();

    // A row can name an ICON instead of taking a generated avatar. The avatar is
    // right when the row is a person (it makes strangers distinguishable at a
    // glance); it is nonsense when the row is a folder or a file, where a random
    // coloured sigil says nothing and the type says everything.
    final iconName = (it['icon'] ?? '').toString();

    return InkWell(
      onTap: () => widget.onTap(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (avatar.startsWith('file:'))
              // A content-addressed media token (e.g. a torrent's favicon-style
              // icon): render from the local archive, fetching if we do not hold
              // it yet. Falls back to the generated avatar until it lands.
              _TokenAvatar(token: avatar, seed: id, size: 44)
            else if (avatar.isNotEmpty)
              ClipOval(
                child: Image.network(
                  avatar,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      GeneratedAvatar(seed: id, size: 44),
                ),
              )
            else if (iconName.isEmpty)
              GeneratedAvatar(seed: id, size: 44)
            else
              SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  geoUiResolveIcon(iconName),
                  size: 30,
                  color: cs.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  if (tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final t in tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primaryContainer.withAlpha(110),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (action.isNotEmpty && actionLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              filled
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: () => widget.onAction(action, id),
                      child: Text(actionLabel),
                    )
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: () => widget.onAction(action, id),
                      child: Text(actionLabel),
                    ),
            ],
            for (final b in buttons)
              IconButton(
                icon: Icon(_rowIcon((b['icon'] ?? '').toString()), size: 20),
                tooltip: (b['tip'] ?? '').toString(),
                visualDensity: VisualDensity.compact,
                onPressed: () => widget.onAction((b['action']).toString(), id),
              ),
            if (menu.isNotEmpty)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: 'More',
                onSelected: (v) => widget.onAction(v, id),
                itemBuilder: (_) => [
                  for (final m in menu)
                    PopupMenuItem<String>(
                      value: (m['value'] ?? '').toString(),
                      child: Text((m['label'] ?? m['value'] ?? '').toString()),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  IconData _rowIcon(String name) {
    switch (name) {
      case 'edit':
        return Icons.edit_outlined;
      case 'delete':
      case 'remove':
        return Icons.remove_circle_outline;
      case 'add':
        return Icons.add_circle_outline;
      case 'star':
      case 'default':
        return Icons.star_outline;
      case 'lock':
      case 'access':
        return Icons.lock_outline;
      case 'settings':
        return Icons.settings_outlined;
      case 'mail':
      case 'message':
        return Icons.mail_outline;
      default:
        return Icons.more_horiz;
    }
  }
}

/// A circular avatar rendered from a content-addressed media token (`file:<sha>.
/// <ext>`) — a torrent's favicon-style icon. Reads the bytes from the local
/// archive, kicks off a fetch when we do not hold them yet, and shows the
/// generated avatar until they land (so the row is never blank).
class _TokenAvatar extends StatefulWidget {
  final String token;
  final String seed;
  final double size;
  const _TokenAvatar({
    required this.token,
    required this.seed,
    this.size = 44,
  });

  @override
  State<_TokenAvatar> createState() => _TokenAvatarState();
}

class _TokenAvatarState extends State<_TokenAvatar> {
  Uint8List? _bytes;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TokenAvatar old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) {
      _bytes = null;
      _poll?.cancel();
      _poll = null;
      _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _load() {
    final ref = MediaRef.parse(widget.token);
    if (ref == null) return;
    final a = sharedMediaArchive();
    if (a == null) return;
    final b = a.get(ref.sha256);
    if (b != null && b.isNotEmpty) {
      setState(() => _bytes = b);
      return;
    }
    // Not held yet — pull it (icons are tiny) and poll briefly for arrival.
    // ignore: discarded_futures
    resolveSharedMedia(ref.sha256, ref.ext);
    _poll = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final bb = sharedMediaArchive()?.get(ref.sha256);
      if (bb != null && bb.isNotEmpty) {
        t.cancel();
        setState(() => _bytes = bb);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return GeneratedAvatar(seed: widget.seed, size: widget.size);
    }
    return ClipOval(
      child: Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            GeneratedAvatar(seed: widget.seed, size: widget.size),
      ),
    );
  }
}
