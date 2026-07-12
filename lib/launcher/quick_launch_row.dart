part of 'launcher.dart';

/// The icon dock in the collapsed all-apps peek: the wapps the user pinned
/// there, else the ones they open most, topped up from the installed list so
/// the row is never short.
class _QuickLaunchRow extends StatefulWidget {
  final List<_LauncherEntry> entries;

  const _QuickLaunchRow({required this.entries});

  @override
  State<_QuickLaunchRow> createState() => _QuickLaunchRowState();
}

class _QuickLaunchRowState extends State<_QuickLaunchRow> {
  static const int _slots = 4;

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
    final preferred = await LaunchCountStore.instance.preferredDock(_slots);
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
          _slots,
          onBars: onBars,
        );
        if (selected.isEmpty) return const SizedBox.shrink();
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
            ],
          ),
        );
      },
    );
  }
}
