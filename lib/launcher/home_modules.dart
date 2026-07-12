part of 'launcher.dart';

/// Resolve one home-screen slot (module bars or dock) to concrete tiles.
///
/// [preferred] is the user's pinned order, or the most-used ranking when they
/// pinned nothing. Entries named there come first, in that order; the slot is
/// then topped up from [entries] so it is never short just because the user has
/// launched only one wapp. Folder tiles (no `wappId`) are never eligible.
List<_LauncherEntry> _resolveHomeSlot(
  List<_LauncherEntry> entries,
  List<String> preferred,
  int count,
) {
  final byId = {
    for (final e in entries)
      if (e.wappId != null) e.wappId!: e,
  };
  final picked = <_LauncherEntry>[];
  final taken = <String>{};
  for (final id in preferred) {
    final e = byId[id];
    if (e == null || !taken.add(id)) continue;
    picked.add(e);
    if (picked.length == count) return picked;
  }
  for (final e in entries) {
    final id = e.wappId;
    if (id == null || !taken.add(id)) continue;
    picked.add(e);
    if (picked.length == count) break;
  }
  return picked;
}

/// Resolve the DOCK, with an alert bubble-up: a wapp with unread activity floats
/// to the front, and one that isn't docked at all gets pulled in.
///
/// The point is that the dock is where you look to see if anything happened. A
/// badge is no use on a tile that is three swipes away inside the app sheet.
///
/// Ordering is a pure function of (preferred, unread), so it only moves when the
/// unread set moves — the icons must not shuffle under the user's finger on
/// every rebuild. Among alerting wapps, ones already in the dock keep their
/// existing dock order; only then are off-dock alerters pulled in (most unread
/// first, id as the final tiebreak so it is deterministic). An explicit pin is
/// never displaced by an alert — it is displaced only by another alert that was
/// already ahead of it.
///
/// The module BARS deliberately do not do this: they are the user's chosen
/// shortcuts and must stay put.
///
/// [onBars] is what those bars are already showing. The dock skips them and
/// takes the next wapps down the list instead — the same wapp as a big bar AND
/// a dock icon is a wasted slot on both, on a home screen that only has seven.
/// An explicit dock pin still wins: if the user deliberately pinned it to both,
/// that is their call, not a bug.
List<_LauncherEntry> _resolveDockSlot(
  List<_LauncherEntry> entries,
  List<String> preferred,
  Map<String, int> unread,
  int count, {
  Set<String> onBars = const {},
}) {
  final prefs = PreferencesService.instanceSync;
  final pool = onBars.isEmpty
      ? entries
      : [
          for (final e in entries)
            if (e.wappId == null ||
                !onBars.contains(e.wappId) ||
                (prefs?.isPinnedToDock(e.wappId!) ?? false))
              e,
        ];
  final base = _resolveHomeSlot(pool, preferred, count);
  int unreadOf(_LauncherEntry e) =>
      e.wappId == null ? 0 : WappUnreadService.instance.totalFor(e.wappId!);

  final alerting = [
    for (final e in pool)
      if (e.wappId != null && unreadOf(e) > 0) e,
  ];
  if (alerting.isEmpty) return base;

  int dockIndex(_LauncherEntry e) =>
      base.indexWhere((b) => b.wappId == e.wappId);

  alerting.sort((a, b) {
    // Already-docked alerters first, in their existing dock order — an alert
    // should not make the dock rearrange itself more than it has to.
    final ai = dockIndex(a), bi = dockIndex(b);
    final aDocked = ai >= 0, bDocked = bi >= 0;
    if (aDocked != bDocked) return aDocked ? -1 : 1;
    if (aDocked && ai != bi) return ai - bi;
    final an = unreadOf(a), bn = unreadOf(b);
    if (an != bn) return bn - an;
    return a.wappId!.compareTo(b.wappId!);
  });

  final picked = <_LauncherEntry>[];
  final taken = <String>{};
  for (final e in [...alerting, ...base]) {
    final id = e.wappId;
    if (id == null || !taken.add(id)) continue;
    picked.add(e);
    if (picked.length == count) break;
  }
  return picked;
}

/// Pin/unpin [entry] to the home module bars or the dock. Shown on long-press
/// of a module bar; the grid tiles fold the same two actions into their own
/// context menu. No-op for folder tiles (no `wappId`).
Future<void> _showHomePinMenu(BuildContext context, _LauncherEntry entry) async {
  final wappId = entry.wappId;
  if (wappId == null) return;
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return;
  final box = Overlay.of(context).context.findRenderObject() as RenderBox;
  final target = context.findRenderObject() as RenderBox;
  final origin = target.localToGlobal(target.size.center(Offset.zero));
  final selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(origin & const Size(1, 1), Offset.zero & box.size),
    items: _homePinMenuItems(prefs, wappId),
  );
  await _applyHomePinChoice(selected, wappId, prefs);
}

List<PopupMenuEntry<String>> _homePinMenuItems(
  PreferencesService prefs,
  String wappId,
) {
  final onBars = prefs.isPinnedToModules(wappId);
  final onDock = prefs.isPinnedToDock(wappId);
  return [
    PopupMenuItem(
      value: 'pin-modules',
      child: Row(
        children: [
          Icon(onBars ? Icons.push_pin : Icons.push_pin_outlined, size: 18),
          const SizedBox(width: 10),
          Text(onBars ? 'Unpin from home bars' : 'Pin to home bars'),
        ],
      ),
    ),
    PopupMenuItem(
      value: 'pin-dock',
      child: Row(
        children: [
          Icon(onDock ? Icons.star : Icons.star_outline, size: 18),
          const SizedBox(width: 10),
          Text(onDock ? 'Unpin from dock' : 'Pin to dock'),
        ],
      ),
    ),
  ];
}

Future<void> _applyHomePinChoice(
  String? selected,
  String wappId,
  PreferencesService prefs,
) async {
  if (selected == 'pin-modules') {
    await LaunchCountStore.instance
        .setPinnedToModules(wappId, !prefs.isPinnedToModules(wappId));
  } else if (selected == 'pin-dock') {
    await LaunchCountStore.instance
        .setPinnedToDock(wappId, !prefs.isPinnedToDock(wappId));
  }
}

/// The rectangular launcher bars filling the middle of the home screen: the
/// wapps the user pinned there, else the ones they open most.
class _ModuleBars extends StatefulWidget {
  final List<_LauncherEntry> entries;

  const _ModuleBars({required this.entries});

  @override
  State<_ModuleBars> createState() => _ModuleBarsState();
}

class _ModuleBarsState extends State<_ModuleBars> {
  static const int _slots = 3;

  List<String> _preferred = const [];
  String _signature = '';

  @override
  void initState() {
    super.initState();
    _signature = _entrySignature(widget.entries);
    _load();
    LaunchCountStore.instance.revision.addListener(_load);
  }

  @override
  void dispose() {
    LaunchCountStore.instance.revision.removeListener(_load);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ModuleBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _entrySignature(widget.entries);
    if (next != _signature) {
      _signature = next;
      _load();
    }
  }

  Future<void> _load() async {
    final preferred = await LaunchCountStore.instance.preferredModules(_slots);
    if (mounted) setState(() => _preferred = preferred);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _resolveHomeSlot(widget.entries, _preferred, _slots);
    if (selected.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in selected)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ModuleBar(entry: e),
            ),
        ],
      ),
    );
  }
}

String _entrySignature(List<_LauncherEntry> entries) =>
    entries.where((e) => e.wappId != null).map((e) => e.wappId!).join('\n');

class _ModuleBar extends StatelessWidget {
  final _LauncherEntry entry;

  const _ModuleBar({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = entry.color;
    return Material(
      color: Color.alphaBlend(accent.withValues(alpha: 0.16), cs.surface),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: entry.onTap,
        onLongPress: entry.wappId == null
            ? null
            : () => _showHomePinMenu(context, entry),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              _ModuleBarIcon(entry: entry, accent: accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (entry.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 48x48 rounded icon chip on the left of a module bar. Mirrors the tile
/// icon rules: SVG, then emoji/text, then a Material glyph.
class _ModuleBarIcon extends StatelessWidget {
  final _LauncherEntry entry;
  final Color accent;

  const _ModuleBarIcon({required this.entry, required this.accent});

  @override
  Widget build(BuildContext context) {
    final svg = entry.svgIconPath;
    final text = entry.textIcon;
    // Cached SVG bytes (shared with the grid tiles) — never a per-build disk
    // read. On web the platform stub yields null and we fall through to the
    // Material glyph.
    Uint8List? svgBytes;
    if (svg != null && svg.isNotEmpty) {
      svgBytes = _svgIconBytes(svg);
    }
    Widget inner;
    if (svgBytes != null) {
      inner = Padding(
        padding: const EdgeInsets.all(6),
        child: SvgPicture.memory(
          svgBytes,
          fit: BoxFit.contain,
          theme: const SvgTheme(currentColor: Colors.white),
          placeholderBuilder: (_) => const SizedBox.shrink(),
        ),
      );
    } else if (text != null && text.isNotEmpty) {
      inner = ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(text, style: const TextStyle(fontSize: 22)),
          ),
        ),
      );
    } else {
      inner = Icon(entry.icon, color: Colors.white, size: 26);
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: inner,
    );
  }
}
