part of 'launcher.dart';

/// The icon dock in the collapsed all-apps peek: the wapps the user pinned
/// there, else the ones they open most, topped up from the installed list so
/// the row is never short.
class _QuickLaunchRow extends StatefulWidget {
  final List<_LauncherEntry> entries;

  /// Non-null where the sheet cannot be swiped open (desktop). The LAST dock
  /// slot then becomes an all-apps button instead of a fourth wapp — the grid
  /// has to be reachable at all before a fourth shortcut into it is worth a
  /// slot, and everything the slot gave up is one click away inside it.
  final VoidCallback? onOpenAll;

  const _QuickLaunchRow({required this.entries, this.onOpenAll});

  @override
  State<_QuickLaunchRow> createState() => _QuickLaunchRowState();
}

class _QuickLaunchRowState extends State<_QuickLaunchRow> {
  static const int _slots = 4;

  /// Slots left for wapps once the all-apps button has taken one.
  int get _wappSlots => widget.onOpenAll == null ? _slots : _slots - 1;

  List<String> _preferred = const [];

  /// What the module bars are showing, so the dock can resolve around them: the
  /// same wapp as a big bar AND a dock icon wastes one of only four dock slots
  /// on something already a thumb's width away.
  List<String> _moduleFavourites = const [];
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
  void didUpdateWidget(covariant _QuickLaunchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _entrySignature(widget.entries);
    if (next != _signature) {
      _signature = next;
      _load();
    }
  }

  Future<void> _load() async {
    final preferred = await LaunchCountStore.instance.preferredDock(_wappSlots);
    final modules = await LaunchCountStore.instance.preferredModules(3);
    if (mounted) {
      setState(() {
        _preferred = preferred;
        _moduleFavourites = modules;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on every unread change: a wapp that just gained a notification has
    // to be able to float into the dock immediately, not at the next scan.
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: WappUnreadService.instance.counts,
      builder: (context, unread, _) {
        // The bars resolve themselves from the same inputs, so resolving them
        // again here gives exactly the set they are showing.
        final onBars = {
          for (final e in _resolveHomeSlot(widget.entries, _moduleFavourites, 3))
            if (e.wappId != null) e.wappId!,
        };
        final selected = _resolveDockSlot(
          widget.entries,
          _preferred,
          unread,
          _wappSlots,
          onBars: onBars,
        );
        final onOpenAll = widget.onOpenAll;
        if (selected.isEmpty && onOpenAll == null) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: 86,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in selected)
                Expanded(
                  // Keyed by wapp so Flutter moves the existing icon when the
                  // order changes instead of rebuilding a fresh one in place.
                  key: ValueKey(e.wappId),
                  child: _AppIcon(
                    name: e.name,
                    icon: e.icon,
                    textIcon: e.textIcon,
                    svgIconPath: e.svgIconPath,
                    color: e.color,
                    modified: e.modified,
                    onTap: e.onTap,
                    onEdit: e.onEdit,
                    wappId: e.wappId,
                    wappDir: e.wappDir,
                  ),
                ),
              if (onOpenAll != null)
                Expanded(
                  key: const ValueKey('all-apps'),
                  child: _AllAppsButton(onTap: onOpenAll),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The all-apps affordance: the same 56px tile the wapps use, so the dock still
/// reads as one row. Neutral rather than branded — it opens the grid, it is not
/// another app in it.
class _AllAppsButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AllAppsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.apps, size: 28, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          const Text(
            'Apps',
            style: TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
