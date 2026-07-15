/// GeoUI Flutter renderer — turns AST blocks into Material 3 widgets.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../i18n_context.dart';
import 'geoui_ast.dart';
import '../../editor/code_editor_field.dart';
import 'widgets/icon_field.dart';
import 'widgets/media_view.dart' show MediaThumbnail, GalleryMediaTile;
import '../../util/media_ref.dart' show MediaRef;
import 'widgets/log_view_field.dart';
import 'widgets/stats_grid_field.dart';
import 'widgets/popularity_chart_field.dart';
import 'widgets/chat_view_field.dart';

/// Bindings interface for reading/writing field values.
abstract class GeoUiBindings {
  dynamic getValue(String fieldName);
  void setValue(String fieldName, dynamic value);
}

/// Action callback: fired when an action block is triggered.
typedef GeoUiActionCallback = void Function(String actionName);

/// Renders a GeoUI screen block as a Flutter widget.
class GeoUiScreenRenderer extends StatefulWidget {
  final GeoUiBlock screen;
  final GeoUiBindings bindings;
  final GeoUiActionCallback? onAction;

  /// Per-wapp translation context. Every string attribute (label,
  /// tip, hint, default, option label, action label, confirm label,
  /// the text of `label` blocks …) is piped through
  /// [I18nContext.resolve] so authors can use `@key` sentinels in
  /// their .ui.json and ship `lang/<locale>.json` sidecars. When
  /// null (legacy or test callers), an empty context is used and
  /// everything passes through as-is.
  final I18nContext? i18n;

  /// Resolves a `$type:"image"` field's value (a media token / data: URI /
  /// path) to an [ImageProvider] for display. Null → images show a placeholder.
  /// Supplied by the host (wapp_page) which owns the MediaArchive.
  final ImageProvider? Function(String value)? resolveImage;

  const GeoUiScreenRenderer({
    super.key,
    required this.screen,
    required this.bindings,
    this.onAction,
    this.i18n,
    this.resolveImage,
  });

  @override
  State<GeoUiScreenRenderer> createState() => _GeoUiScreenRendererState();
}

class _GeoUiScreenRendererState extends State<GeoUiScreenRenderer> {
  /// Cached controllers keyed by field name. Prevents the cursor-reset
  /// bug caused by creating a new TextEditingController on every build.
  final Map<String, TextEditingController> _controllers = {};

  TextEditingController _controllerFor(String fieldName, String text) {
    final existing = _controllers[fieldName];
    if (existing != null) {
      // Only update if the text changed externally (e.g. project load),
      // not from the user typing (which already updated the controller).
      if (existing.text != text) {
        existing.text = text;
      }
      return existing;
    }
    final ctrl = TextEditingController(text: text);
    _controllers[fieldName] = ctrl;
    return ctrl;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Lazy shortcut for [I18nContext.resolve] that also preserves the
  /// "null in → null out" contract of nullable string getters. Every
  /// user-visible string in this renderer goes through here so wapps
  /// can swap `label: "Title"` for `label: "@settings.title"` with
  /// zero code changes on the author side.
  String? _t(String? raw) {
    if (raw == null) return null;
    return widget.i18n?.resolve(raw) ?? raw;
  }

  /// Non-null variant for sites that always have a value (action
  /// labels, options, ...).
  String _tRequired(String raw) => widget.i18n?.resolve(raw) ?? raw;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final children = widget.screen.children;

    // Render children in document order. Runs of adjacent `action`
    // children get collapsed into a single Wrap so many buttons flow
    // naturally (multiple rows on narrow screens, a single row on
    // wide ones) and stay grouped next to the preceding heading.
    final rendered = <Widget>[];
    var i = 0;
    while (i < children.length) {
      if (children[i].keyword == 'action') {
        final run = <GeoUiBlock>[];
        while (i < children.length && children[i].keyword == 'action') {
          run.add(children[i]);
          i++;
        }
        rendered.add(Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.start,
            children: [for (final a in run) _renderAction(a)],
          ),
        ));
      } else {
        rendered.add(_renderBlock(children[i]));
        i++;
      }
    }

    final screenTip = _t(widget.screen.getString('tip'));
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Screen tip
          if (screenTip != null && screenTip.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                screenTip,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          ...rendered,
        ],
      ),
    );
  }

  Widget _renderBlock(GeoUiBlock block) {
    return switch (block.keyword) {
      'group' => _renderGroup(block),
      'field' => _renderField(block),
      'action' => _renderAction(block),
      'label' => _renderLabel(block),
      _ => const SizedBox.shrink(),
    };
  }

  // ── Group ───────────────────────────────────────────────────────────

  Widget _renderGroup(GeoUiBlock group) {
    // Spec §14.1 — a `<group $type="menu">` renders as a single
    // overflow icon button that opens a popup of its action children.
    if (group.type == 'menu') return _renderMenuGroup(group);
    // Spec §14.2 — a `<group $type="header-actions">`. The canonical
    // home is the host AppBar; aurora renders them inline as a compact
    // action row (keeps them visible without an AppBar round-trip).
    if (group.type == 'header-actions') return _renderHeaderActions(group);

    final cs = Theme.of(context).colorScheme;
    final tip = _t(group.getString('tip'));
    // Group names aren't usually translatable (they're slugs more
    // than labels), but authors can still opt in by passing
    // `@key` — the resolver is lossless for literal strings.
    final name = _t(group.name);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          if (name != null && name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                name,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
              ),
            ),
          if (tip != null && tip.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                tip,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          // Card containing fields
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
            color: cs.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < group.children.length; i++) ...[
                  _renderGroupChild(group.children[i]),
                  if (i < group.children.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: cs.outlineVariant.withAlpha(50),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Render a child inside a group card — each field gets consistent
  /// list-tile-style padding.
  Widget _renderGroupChild(GeoUiBlock block) {
    return switch (block.keyword) {
      'field' => _renderFieldInCard(block),
      'label' => _renderLabel(block),
      _ => _renderBlock(block),
    };
  }

  // ── Menu / header-action groups (spec §14) ─────────────────────────

  IconData _iconFromName(String name) => geoUiResolveIcon(name);

  /// `<group $type="menu">` → a popup-menu icon button. Selecting an
  /// item dispatches the same {type:"action"} message inline actions do.
  Widget _renderMenuGroup(GeoUiBlock group) {
    final actions = group.children
        .where((c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty)
        .toList();
    if (actions.isEmpty) return const SizedBox.shrink();

    final iconName = group.getString('icon') ?? 'menu';
    final tip = _t(group.getString('tip')) ?? 'Menu';
    final groupLabel = _t(group.name);

    final button = PopupMenuButton<String>(
      tooltip: tip,
      icon: Icon(_iconFromName(iconName)),
      onSelected: (name) => widget.onAction?.call(name),
      itemBuilder: (_) => [
        for (final a in actions)
          PopupMenuItem<String>(
            value: a.name!,
            child: Text(_t(a.getString('label')) ?? a.name!),
          ),
      ],
    );

    if (groupLabel == null || groupLabel.isEmpty) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [button, const SizedBox(width: 4), Text(groupLabel)],
    );
  }

  /// `<group $type="header-actions">` → a right-aligned row of compact
  /// action buttons. Each child is either an `<action>` (icon button)
  /// or a nested `<group $type="menu">` (popup button).
  Widget _renderHeaderActions(GeoUiBlock group) {
    final items = <Widget>[];
    for (final child in group.children) {
      if (child.keyword == 'group' && child.type == 'menu') {
        items.add(_renderMenuGroup(child));
      } else if (child.keyword == 'action' && (child.name ?? '').isNotEmpty) {
        final name = child.name!;
        final iconName = child.getString('icon');
        final label = _t(child.getString('label')) ?? name;
        items.add(IconButton(
          tooltip: label,
          icon: Icon(_iconFromName(iconName ?? 'settings')),
          onPressed: () => widget.onAction?.call(name),
        ));
      }
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: items),
    );
  }

  // ── Field ───────────────────────────────────────────────────────────

  Widget _renderField(GeoUiBlock field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _renderFieldWidget(field),
    );
  }

  /// Field rendered inside a group card — with consistent padding.
  Widget _renderFieldInCard(GeoUiBlock field) {
    final type = field.type ?? 'string';
    // Sliders need special layout
    if ((type == 'float' || type == 'int') &&
        field.getNumber('min') != null &&
        field.getNumber('max') != null) {
      return _renderSliderField(field);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _renderFieldWidget(field),
    );
  }

  Widget _renderFieldWidget(GeoUiBlock field) {
    final fieldName = field.name ?? '';
    final type = field.type ?? 'string';
    // Field labels and tips are the most translation-heavy surface
    // in GeoUI — every input has at least one. They all route
    // through _t() so `label: "@settings.title_label"` Just Works.
    final label = _t(field.getString('label')) ?? fieldName;
    final tip = _t(field.getString('tip'));

    return switch (type) {
      'bool' => _renderBoolField(fieldName, label, tip, field.getString('apply')),
      'int' => _renderNumericField(fieldName, label, tip,
          isInt: true, block: field),
      'float' => _renderNumericField(fieldName, label, tip,
          isInt: false, block: field),
      'enum' => _renderEnumField(fieldName, label, tip, field),
      'code' => _renderCodeField(fieldName, label, tip, field),
      'log' => _renderLogField(fieldName, label, tip, field),
      'chat' => _renderChatField(fieldName, label, tip, field),
      'icon' => _renderIconField(fieldName, label, tip, field),
      'qr' => _renderQrField(fieldName, label, tip, field),
      'stats' => _renderStatsField(fieldName),
      'popularity' => _renderPopularityField(fieldName),
      'image' => _renderImageField(fieldName, label, tip, field),
      'gallery' => _renderGalleryField(fieldName, label, tip, field),
      _ => _renderStringField(fieldName, label, tip, field),
    };
  }

  /// `$type:"popularity"` — a native monthly bar chart of seeders and unique
  /// leechers (popularity_chart_field.dart). The wapp sets the field value (via
  /// `ui.field.set`) to a list of `{ym, seeders, leechers}`.
  Widget _renderPopularityField(String name) {
    final raw = widget.bindings.getValue(name);
    List monthsRaw = const [];
    if (raw is List) {
      monthsRaw = raw;
    } else if (raw is Map && raw['months'] is List) {
      monthsRaw = raw['months'] as List;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is List) monthsRaw = d;
        else if (d is Map && d['months'] is List) monthsRaw = d['months'] as List;
      } catch (_) {}
    }
    final months = monthsRaw
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
    return PopularityChartField(months: months);
  }

  /// `$type:"stats"` — the native dashboard grid (stats_grid_field.dart). Tiles
  /// arrive from the wapp via `ui.stats.set`; a tile with `tap:true` fires
  /// `<field>_tap` with `<field>_id`, the people-row contract.
  Widget _renderStatsField(String name) {
    final raw = widget.bindings.getValue(name);
    final tiles = raw is List
        ? raw
            .whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .toList()
        : const <Map<String, dynamic>>[];
    return StatsGridField(
      tiles: tiles,
      onTap: (id) {
        widget.bindings.setValue('${name}_id', id);
        widget.onAction?.call('${name}_tap');
      },
    );
  }

  /// `$type:"gallery"` — the artwork of a listing: a wide banner, a cover, and a
  /// row of stills/clips. Read-only; the wapp sets the value (via ui.field.set)
  /// to the JSON that `hal_folder_media` returns:
  ///
  ///   {"banner":{"token":"file:….jpg"},"cover":{…},"trailer":{…},
  ///    "gallery":[{…},…]}
  ///
  /// Every tile is a [MediaThumbnail], which already gives a poster for a video,
  /// inline playback for a .webm, a fetch-progress chip while the bytes are
  /// still coming, and a fullscreen viewer on tap. None of that is re-invented
  /// here — this is layout over the widget chat already uses.
  static String _fmtGalleryBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1048576).toStringAsFixed(1)} MB';
    return '${(n / 1073741824).toStringAsFixed(2)} GB';
  }

  Widget _renderGalleryField(
      String name, String label, String? tip, GeoUiBlock field) {
    final raw = widget.bindings.getValue(name)?.toString() ?? '';
    if (raw.isEmpty) return const SizedBox.shrink();
    Map<String, dynamic> g;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SizedBox.shrink();
      g = decoded.cast<String, dynamic>();
    } catch (_) {
      return const SizedBox.shrink();
    }

    MediaRef? refOf(Object? item) {
      if (item is! Map) return null;
      final token = (item['token'] ?? '').toString();
      return token.isEmpty ? null : MediaRef.parse(token);
    }


    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final banner = refOf(g['banner']);
    final cover = refOf(g['cover']);
    final trailer = refOf(g['trailer']);
    final gallery = ((g['gallery'] as List?) ?? const []).toList();

    final title = (g['title'] ?? '').toString();
    final cat = (g['cat'] ?? '').toString();
    final adult = g['adult'] == true;
    final desc = (g['desc'] ?? '').toString();
    final tags = ((g['tags'] as List?) ?? const [])
        .map((t) => t.toString())
        .where((t) => t.isNotEmpty)
        .toList();

    // The compact file browser (feedback 2): a simple list under the hero, with
    // a button to open the full-screen browser.
    final files = ((g['files'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final path = (g['path'] ?? '').toString();

    // Nothing visual to show? Fall back to a one-line summary of the payload
    // (feedback 3), so an artless torrent still reads as more than a blank box.
    final hasPreview =
        banner != null || cover != null || trailer != null || gallery.isNotEmpty;
    final fileCount = (g['fileCount'] as num?)?.toInt() ?? 0;
    final totalBytes = (g['totalBytes'] as num?)?.toInt() ?? 0;
    // Seeders known to the Indexers (cached; -1 when the field is absent).
    final seeders = (g['seeders'] as num?)?.toInt() ?? -1;

    if (banner == null &&
        cover == null &&
        trailer == null &&
        gallery.isEmpty &&
        title.isEmpty &&
        desc.isEmpty &&
        files.isEmpty &&
        path.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget chip(String text, {Color? bg, Color? fg}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: bg ?? cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(text,
              style: tt.labelSmall?.copyWith(
                  color: fg ?? cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
        );

    // The identity block: category + adult, then the tags. The TITLE is NOT
    // repeated here — whoever shows this hero (the torrent's Info screen) already
    // carries the name in its app bar, so a title line would say it twice.
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cat.isNotEmpty || adult)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              if (cat.isNotEmpty)
                chip(cat[0].toUpperCase() + cat.substring(1),
                    bg: cs.primaryContainer, fg: cs.onPrimaryContainer),
              if (adult)
                chip('18+', bg: cs.errorContainer, fg: cs.onErrorContainer),
            ]),
          ),
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final t in tags) chip(t)],
            ),
          ),
      ],
    );

    // Screenshots (trailer first — it is the thing a person most wants to press)
    // scroll sideways, like every store page, so they never crowd the text.
    // A screenshot the device does not hold shows a download button, not a
    // spinner — feedback 5: pull it only when asked, with a % wheel meanwhile.
    final strip = <Widget>[
      if (trailer != null) _shot(trailer),
      for (final item in gallery)
        if (refOf(item) != null) _shot(refOf(item)!),
    ];

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (banner != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 6,
              child: GalleryMediaTile(ref: banner),
            ),
          ),
        if (banner != null) const SizedBox(height: 14),
        // Poster beside the identity block — the shape of a store listing.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover != null) ...[
              SizedBox(
                width: 104,
                height: 156,
                child: GalleryMediaTile(ref: cover),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(child: meta),
          ],
        ),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(desc,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ],
        if (seeders >= 0) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.upload_rounded, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text('$seeders seeder${seeders == 1 ? '' : 's'}',
                style: tt.bodyMedium?.copyWith(
                    color: cs.onSurface, fontWeight: FontWeight.w600)),
            Text('  ·  others holding this now',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ],
        if (!hasPreview && fileCount > 0) ...[
          const SizedBox(height: 14),
          Text(
            'No preview was provided for this torrent. '
            'It holds $fileCount file${fileCount == 1 ? '' : 's'}'
            '${totalBytes > 0 ? ', ${_fmtGalleryBytes(totalBytes)} in total' : ''}.',
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        // No "Screenshots" heading — a horizontal strip of thumbnails is
        // self-evidently a gallery.
        if (strip.isNotEmpty) ...[
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < strip.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  strip[i],
                ],
              ],
            ),
          ),
        ],
        if (files.isNotEmpty || path.isNotEmpty)
          _fileList(name, files, path, totalBytes, cs, tt),
      ],
    );

    return content;
  }

  /// The compact, tappable file list under a listing hero. Rows fire a command
  /// via the field's onAction (the selection rides a field so a 64-char sha is
  /// not truncated into the short command buffer).
  Widget _fileList(String field, List<Map<String, dynamic>> files, String path,
      int totalBytes, ColorScheme cs, TextTheme tt) {
    void fire(String action, [String? sel]) {
      if (sel != null) widget.bindings.setValue('${field}_sel', sel);
      widget.onAction?.call(action);
    }

    Widget row(IconData icon, String title, String? sub, VoidCallback onTap) =>
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(children: [
              Icon(icon, size: 22, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium),
              ),
              if (sub != null)
                Text(sub, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        // "Files (1.2 GB)" — the whole-torrent total, so the size is visible
        // without opening the browser. (Browse now lives in the ☰ menu.)
        Text(
          totalBytes > 0 ? 'Files (${_fmtGalleryBytes(totalBytes)})' : 'Files',
          style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
        if (path.isNotEmpty)
          row(Icons.arrow_upward, '..', 'up', () => fire('${field}_up')),
        for (final f in files)
          () {
            final isDir = f['dir'] == true;
            final title = (f['title'] ?? '').toString();
            final sub = (f['sub'] ?? '').toString();
            final id = (f['id'] ?? '').toString();
            final iconName = (f['icon'] ?? '').toString();
            return row(
              iconName.isEmpty
                  ? (isDir ? Icons.folder : Icons.insert_drive_file)
                  : geoUiResolveIcon(iconName),
              title,
              sub.isEmpty ? null : sub,
              () => fire(isDir ? '${field}_cd' : '${field}_open', id),
            );
          }(),
      ],
    );
  }

  /// One 16:9 screenshot/clip tile for the gallery strip (download-on-tap).
  Widget _shot(MediaRef ref) => SizedBox(
        width: 168,
        height: 94,
        child: GalleryMediaTile(ref: ref, autoFetch: false),
      );


  /// `$type:"qr"` — render a QR code of the field's string value (e.g. a circle
  /// id to share). Read-only; the value is set by the wapp via ui.field.set.
  Widget _renderQrField(String name, String label, String? tip, GeoUiBlock field) {
    final cs = Theme.of(context).colorScheme;
    final data = widget.bindings.getValue(name)?.toString() ?? '';
    final size = field.getNumber('size')?.toDouble() ?? 220.0;
    // Only show a heading if the wapp set an explicit label — don't fall back to
    // the raw field name (which rendered as "share_qr").
    final heading = _t(field.getString('label'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (heading != null && heading.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(heading, style: Theme.of(context).textTheme.titleSmall),
          ),
        if (data.isEmpty)
          Text('Nothing to share yet',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant))
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: data,
              size: size,
              backgroundColor: Colors.white,
              // ignore: deprecated_member_use
              foregroundColor: Colors.black,
            ),
          ),
        if (tip != null && tip.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tip,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ],
    );
  }

  /// `$type:"image"` — show the picture resolved from the field value and a
  /// "Choose…" button. Picking is delegated to the host: the button fires the
  /// `<name>__pickimage` action, which the host handles (native picker → store
  /// in the content-addressed archive → set the field value to the token).
  Widget _renderImageField(
      String name, String label, String? tip, GeoUiBlock field) {
    final cs = Theme.of(context).colorScheme;
    final value = widget.bindings.getValue(name)?.toString() ?? '';
    final provider =
        value.isEmpty ? null : widget.resolveImage?.call(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              shape: BoxShape.circle,
              image: provider == null
                  ? null
                  : DecorationImage(image: provider, fit: BoxFit.cover),
            ),
            child: provider == null
                ? Icon(Icons.photo_camera_outlined,
                    size: 40, color: cs.onSurfaceVariant)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(value.isEmpty ? 'Choose picture' : 'Change picture'),
            onPressed: () => widget.onAction?.call('${name}__pickimage'),
          ),
        ),
        if (tip != null && tip.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(tip,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ],
    );
  }

  Widget _renderChatField(
      String name, String label, String? tip, GeoUiBlock field) {
    // Messages are a List<Map> seeded empty by _seedFieldDefaults. Each
    // entry: {dir:'in'|'out', from, text, time}. On send we stash the
    // typed text in a companion `<name>_input` binding and fire the
    // `<name>_send` action so the host's _sendCommand bundles it to the
    // wapp (no new host protocol needed).
    final stored = widget.bindings.getValue(name);
    final messages = stored is List
        ? stored.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
    return ChatViewField(
      fieldName: name,
      label: label,
      tip: tip,
      hint: field.getString('hint') ?? 'Message…',
      messages: messages,
      onSend: (text) {
        widget.bindings.setValue('${name}_input', text);
        widget.onAction?.call('${name}_send');
      },
    );
  }

  Widget _renderCodeField(
      String name, String label, String? tip, GeoUiBlock field) {
    final languageId = field.getString('language') ?? 'c';
    // Pure read — _loadWapp's _seedFieldDefaults has already written
    // the default text into bindings before the first build. Calling
    // setValue here would trigger setState() inside a build method.
    final current = widget.bindings.getValue(name)?.toString() ?? '';
    // Companion flag in the bindings map that the host can flip at
    // runtime (e.g. App Creator's _loadProject sets
    // `source__readonly = true` when the loaded wapp doesn't ship a
    // main.c). Absent / non-true means the editor stays editable.
    final readOnly = widget.bindings.getValue('${name}__readonly') == true;
    return CodeEditorField(
      fieldName: name,
      label: label,
      tip: readOnly
          ? '${tip ?? ''}\n(read-only — no source shipped with this wapp; '
              'click "Create new wapp" to start fresh)'
          : tip,
      languageId: languageId,
      initialValue: current,
      readOnly: readOnly,
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  Widget _renderIconField(
      String name, String label, String? tip, GeoUiBlock field) {
    // Pure read — _seedFieldDefaults has already written the default
    // into bindings before the first build.
    final current = widget.bindings.getValue(name)?.toString() ?? '';
    return IconField(
      fieldName: name,
      label: label,
      tip: tip,
      initialValue: current,
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  Widget _renderLogField(
      String name, String label, String? tip, GeoUiBlock field) {
    // Pure read — _loadWapp's _seedFieldDefaults seeds an empty
    // List<String> for every log field before the first build. If a
    // log field somehow slips past the seeder (e.g. dynamic screen
    // injection later) we fall back to a throwaway empty list rather
    // than mutating bindings from inside build().
    final stored = widget.bindings.getValue(name);
    final lines = stored is List<String> ? stored : const <String>[];
    return LogViewField(
      fieldName: name,
      label: label,
      tip: tip,
      lines: lines,
    );
  }

  Widget _renderBoolField(String name, String label, String? tip,
      [String? apply]) {
    final cs = Theme.of(context).colorScheme;
    final val = widget.bindings.getValue(name) as bool? ?? false;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: tip != null
          ? Text(tip,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ))
          : null,
      trailing: Switch.adaptive(
        value: val,
        onChanged: (v) {
          widget.bindings.setValue(name, v);
          setState(() {});
          // When the field declares an `apply` command, toggling takes effect
          // immediately (no separate Apply button needed).
          if (apply != null && apply.isNotEmpty) widget.onAction?.call(apply);
        },
      ),
    );
  }

  Widget _renderNumericField(
    String name,
    String label,
    String? tip, {
    required bool isInt,
    required GeoUiBlock block,
  }) {
    final min = block.getNumber('min');
    final max = block.getNumber('max');
    final val = widget.bindings.getValue(name);
    final numVal = val is int ? val.toDouble() : (val as double? ?? min ?? 0);

    if (min != null && max != null) {
      return _renderSliderField(block);
    }

    // No range — use text field
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      keyboardType: TextInputType.number,
      controller: _controllerFor('__num_$name', numVal.toString()),
      onChanged: (v) {
        final parsed = isInt ? int.tryParse(v) : double.tryParse(v);
        if (parsed != null) widget.bindings.setValue(name, parsed);
      },
    );
  }

  /// Slider field rendered inside a card — edge-to-edge slider look.
  Widget _renderSliderField(GeoUiBlock block) {
    final cs = Theme.of(context).colorScheme;
    final fieldName = block.name ?? '';
    final type = block.type ?? 'float';
    final isInt = type == 'int';
    final label = _t(block.getString('label')) ?? fieldName;
    final tip = _t(block.getString('tip'));
    final min = block.getNumber('min')!;
    final max = block.getNumber('max')!;
    final step = block.getNumber('step');
    final val = widget.bindings.getValue(fieldName);
    final numVal = val is int ? val.toDouble() : (val as double? ?? min);
    final divisions = step != null ? ((max - min) / step).round() : null;
    final displayVal =
        isInt ? numVal.round().toString() : numVal.toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    displayVal,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      )),
            ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
            ),
            child: Slider(
              value: numVal.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                widget.bindings.setValue(fieldName, isInt ? v.round() : v);
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderEnumField(
      String name, String label, String? tip, GeoUiBlock field) {
    final cs = Theme.of(context).colorScheme;
    final options = field.childrenOf('option');
    final current = widget.bindings.getValue(name)?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      )),
            ),
          if (tip == null) const SizedBox(height: 8),
          if (options.length <= 4)
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                style: SegmentedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                segments: options.map((o) {
                  final optName = o.name ?? '';
                  final optLabel =
                      _t(o.getString('label')) ?? optName;
                  return ButtonSegment(
                      value: optName, label: Text(optLabel));
                }).toList(),
                selected: {current},
                onSelectionChanged: (v) {
                  widget.bindings.setValue(name, v.first);
                  setState(() {});
                  // Same contract as a bool's `apply`: choosing an option can
                  // take effect at once (a search filter has no Apply button).
                  final apply = field.getString('apply');
                  if (apply != null && apply.isNotEmpty) {
                    widget.onAction?.call(apply);
                  }
                },
              ),
            )
          else
            DropdownButtonFormField<String>(
              value: current.isEmpty ? null : current,
              decoration: InputDecoration(
                labelText: label,
                helperText: tip,
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              items: options.map((o) {
                final optName = o.name ?? '';
                final optLabel =
                    _t(o.getString('label')) ?? optName;
                return DropdownMenuItem(value: optName, child: Text(optLabel));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  widget.bindings.setValue(name, v);
                  setState(() {});
                  final apply = field.getString('apply');
                  if (apply != null && apply.isNotEmpty) {
                    widget.onAction?.call(apply);
                  }
                }
              },
            ),
        ],
      ),
    );
  }

  Widget _renderStringField(
      String name, String label, String? tip, GeoUiBlock field) {
    final hint = _t(field.getString('hint'));
    final readOnly = field.getBool('readonly') ?? false;
    // Multi-line attribute: when true, the TextField grows to [lines]
    // visible rows and accepts the Enter key as a newline. Useful for
    // fields like the install wapp's "Repositories" list where one
    // URL/path lives per line.
    final multiline = field.getBool('multiline') ?? false;
    final lines = (field.getNumber('lines') ?? 6).toInt();
    // Optional hard length cap (shows the live counter + enforces the limit).
    final maxLen = field.getNumber('max')?.toInt();
    // Optional copy-to-clipboard affordance (handy for read-only ids/links).
    final canCopy = field.getBool('copy') ?? false;
    final val = widget.bindings.getValue(name)?.toString() ?? '';
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        helperMaxLines: 3,
        hintText: hint,
        alignLabelWithHint: multiline,
        filled: true,
        suffixIcon: canCopy
            ? IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy',
                onPressed: () {
                  final v = widget.bindings.getValue(name)?.toString() ?? '';
                  Clipboard.setData(ClipboardData(text: v));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
              )
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      readOnly: readOnly,
      maxLength: (maxLen != null && maxLen > 0) ? maxLen : null,
      maxLines: multiline ? lines : 1,
      minLines: multiline ? 3 : 1,
      keyboardType:
          multiline ? TextInputType.multiline : TextInputType.text,
      style: multiline
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      controller: _controllerFor(name, val),
      onChanged: (v) {
        widget.bindings.setValue(name, v);
        // `"live": true` — the wapp wants to react to every keystroke (search
        // as you type). Debounced, so a fast typist does not fire a relay
        // query per letter; the action is named "<field>_changed".
        if (field.getBool('live') == true) {
          _liveDebounce?.cancel();
          _liveDebounce = Timer(
            const Duration(milliseconds: 220),
            () => widget.onAction?.call('${name}_changed'),
          );
        }
      },
    );
  }

  Timer? _liveDebounce;

  // ── Action ──────────────────────────────────────────────────────────

  Widget _renderAction(GeoUiBlock action) {
    final name = action.name ?? '';
    final label = _t(action.getString('label')) ?? name;
    final style = action.getString('style') ?? 'secondary';
    final tip = _t(action.getString('tip'));
    final confirm = action.getBool('confirm') ?? false;
    final confirmLabel = _t(action.getString('confirm-label'));
    // The dialog had a title and nothing else, so a destructive action could
    // only ever ask "Confirm?" — which tells the person nothing about what is
    // about to happen. `confirm-text` is the sentence that says it.
    final confirmText = _t(action.getString('confirm-text'));

    final onPressed = () {
      if (confirm) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(confirmLabel ?? 'Confirm?'),
            content: confirmText == null ? null : Text(confirmText),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onAction?.call(name);
                },
                child: Text(label),
              ),
            ],
          ),
        );
      } else {
        widget.onAction?.call(name);
      }
    };

    Widget button = switch (style) {
      'primary' => FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      'danger' => FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      _ => TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
    };

    if (tip != null) button = Tooltip(message: tip, child: button);
    return button;
  }

  // ── Label ───────────────────────────────────────────────────────────

  Widget _renderLabel(GeoUiBlock label) {
    final rawText = label.getString('text') ?? label.name ?? '';
    final text = _tRequired(rawText);
    final style = label.getString('style');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: style == 'meta'
            ? Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )
            : null,
      ),
    );
  }
}

/// Convenience: render a GeoUI screen as a dialog.
Future<void> showGeoUiDialog({
  required BuildContext context,
  required GeoUiBlock screen,
  required GeoUiBindings bindings,
  GeoUiActionCallback? onAction,
}) {
  final cs = Theme.of(context).colorScheme;

  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: cs.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      screen.name ?? 'Settings',
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      onAction?.call('cancel');
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Flexible(
              child: GeoUiScreenRenderer(
                screen: screen,
                bindings: bindings,
                onAction: (action) {
                  onAction?.call(action);
                  if (action == 'cancel' || action == 'save') {
                    Navigator.of(ctx).pop();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Whitelist of Material icon names wapps may reference in their
/// `.ui.json` (menu trigger icons, header-action icons, …). Anything
/// outside the list falls back to `Icons.menu` so wapps can't reach
/// into arbitrary Material icons by surprise. Top-level so both the
/// renderer and any host AppBar hoisting share one mapping.
IconData geoUiResolveIcon(String name) {
  switch (name) {
    case 'menu':
      return Icons.menu;
    case 'more_vert':
      return Icons.more_vert;
    case 'more_horiz':
      return Icons.more_horiz;
    case 'settings':
      return Icons.settings;
    case 'add':
      return Icons.add;
    case 'edit':
      return Icons.edit;
    case 'tune':
      return Icons.tune;
    case 'filter_list':
      return Icons.filter_list;
    case 'sort':
      return Icons.sort;
    case 'apps':
      return Icons.apps;
    case 'refresh':
      return Icons.refresh;
    case 'bell':
    case 'notifications':
      return Icons.notifications_none;
    case 'thumb_up':
      return Icons.thumb_up_outlined;
    case 'thumb_down':
      return Icons.thumb_down_outlined;
    case 'search':
      return Icons.search;
    case 'share':
      return Icons.share;
    case 'save':
      return Icons.save;
    case 'delete':
      return Icons.delete;
    case 'info':
      return Icons.info_outline;
    case 'link':
      return Icons.link;
    case 'content_copy':
    case 'copy':
      return Icons.content_copy;
    case 'help':
      return Icons.help_outline;
    case 'download':
      return Icons.download;
    case 'upload':
      return Icons.upload;
    case 'play':
      return Icons.play_arrow;
    case 'pause':
      return Icons.pause;
    case 'stop':
      return Icons.stop;
    case 'open':
      return Icons.folder_open;
    case 'folder':
      return Icons.folder;
    case 'folder_shared':
      return Icons.folder_shared;
    case 'create_new_folder':
      return Icons.create_new_folder;
    case 'file':
    case 'description':
    case 'insert_drive_file':
      return Icons.insert_drive_file;
    // File types a browser needs in order to be readable at a glance.
    case 'image':
      return Icons.image_outlined;
    case 'picture_as_pdf':
      return Icons.picture_as_pdf;
    case 'archive':
      return Icons.folder_zip_outlined;
    case 'apk':
    case 'android':
      return Icons.android;
    case 'list':
      return Icons.list;
    case 'category':
      return Icons.category;
    case 'close':
      return Icons.close;
    case 'check':
      return Icons.check;
    case 'star':
      return Icons.star_outline;
    case 'favorite':
      return Icons.favorite_border;
    case 'person_add':
      return Icons.person_add_alt_1;
    case 'person_remove':
      return Icons.person_remove_alt_1;
    case 'home':
      return Icons.home_outlined;
    case 'mail':
    case 'messages':
      return Icons.mail_outline;
    case 'map':
      return Icons.map_outlined;
    case 'people':
    case 'follows':
      return Icons.people_outline;
    case 'chat':
    case 'geochat':
    case 'forum':
      return Icons.forum_outlined;
    case 'visibility':
      return Icons.visibility;
    case 'lock':
      return Icons.lock_outline;
    case 'upgrade':
    case 'update':
      return Icons.upgrade;
    case 'cloud':
      return Icons.cloud_outlined;
    case 'storefront':
    case 'store':
      return Icons.storefront_outlined;
    case 'grid_view':
    case 'grid':
      return Icons.grid_view;
    case 'view_list':
      return Icons.view_list;
    case 'library_music':
    case 'music':
    case 'queue_music':
      return Icons.library_music;
    case 'audiotrack':
    case 'music_note':
    case 'audio':
      return Icons.music_note;
    case 'movie':
    case 'film':
    case 'video':
    case 'movie_outlined':
      return Icons.movie_outlined;
    case 'radio':
      return Icons.radio;
    case 'skip_next':
      return Icons.skip_next;
    case 'skip_previous':
      return Icons.skip_previous;
    case 'shuffle':
      return Icons.shuffle;
    case 'repeat':
      return Icons.repeat;
    default:
      return Icons.menu;
  }
}
