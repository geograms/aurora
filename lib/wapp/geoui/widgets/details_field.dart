/*
 * `$type:"details"` — one thing, explained field by field.
 *
 * The gap this fills: a wapp that wants to show WHAT something is had only the
 * people widget to reach for, and a people row is built for a person — it draws
 * an identicon avatar, a bold name and a subtitle. Point it at the fields of a
 * radio packet and every row grows a meaningless generated face, the
 * explanation truncates into "the station that composed…", and the whole screen
 * reads as a contact list rather than as an account of a message.
 *
 * So this is deliberately not a list of rows-with-avatars. It is a description
 * list: the field's meaning above, its value below in the size you actually
 * read, the wire key beside it in monospace for anyone matching it against the
 * specification, and nothing else competing for attention.
 *
 * Shape pushed by the wapp (ui.field.set, any JSON):
 *
 *   [ {"title": "What it says",
 *      "items": [{"label": "From — the station that composed it",
 *                 "value": "X1RD89",
 *                 "key":   "f",
 *                 "mono":  false}]} ]
 *
 * `key` and `mono` are optional. `mono` is for values that are identifiers
 * rather than words — a hash, a destination, the raw frame — where the shape of
 * the characters matters and proportional text makes them harder to compare.
 */
import 'package:flutter/material.dart';

class DetailsField extends StatelessWidget {
  const DetailsField({super.key, required this.sections, this.emptyText});

  /// `[{title, items:[{label, value, key, mono}]}]`.
  final List<Map<String, dynamic>> sections;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    if (sections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyText?.isNotEmpty == true ? emptyText! : 'Nothing to show.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    // A Column, not a ListView: the screen body this sits in already scrolls,
    // and a ListView inside it has unbounded height — it renders nothing at
    // all, which is exactly how this first shipped.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in sections) ...[
          if ((s['title'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 6),
              child: Text(
                (s['title'] ?? '').toString().toUpperCase(),
                style: t.labelSmall?.copyWith(
                  color: cs.primary,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          for (final raw in ((s['items'] as List?) ?? const []))
            if (raw is Map) _row(context, raw.cast<String, dynamic>()),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> it) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final label = (it['label'] ?? '').toString();
    final value = (it['value'] ?? '').toString();
    final key = (it['key'] ?? '').toString();
    final mono = it['mono'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // What the field MEANS comes first and small: it is the thing a
          // reader needs in order to make sense of the value under it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label.isEmpty ? 'Field' : label,
                  style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              if (key.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    key,
                    style: t.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: cs.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          // The value, at reading size, and never clipped: an address or a raw
          // frame that ends in an ellipsis is exactly the part somebody opened
          // this screen to see.
          SelectableText(
            value.isEmpty ? '—' : value,
            style: (mono
                    ? t.bodyMedium?.copyWith(fontFamily: 'monospace')
                    : t.bodyLarge)
                ?.copyWith(color: cs.onSurface, height: 1.3),
          ),
        ],
      ),
    );
  }
}
