part of 'launcher.dart';

class _AllAppsSheet extends StatefulWidget {
  final List<_LauncherEntry> entries;

  const _AllAppsSheet({required this.entries});

  @override
  State<_AllAppsSheet> createState() => _AllAppsSheetState();
}

class _AllAppsSheetState extends State<_AllAppsSheet> {
  // Collapsed-peek content: 10 gap + 5 handle + 8 gap + 86 dock row + 8 tail.
  // Sized in pixels and converted to a fraction of the actual body height, so
  // the peek shows exactly the handle + dock — never a sliver of the grid.
  static const double _peekPx = 10 + 5 + 8 + 86 + 8;

  List<_LauncherEntry> get entries => widget.entries;

  // How far the sheet is expanded, 0 = collapsed peek, 1 = fully open. Drives
  // the dock fade-out: the dock is a peek affordance, and keeping it above the
  // full grid would show its four wapps twice. A ValueNotifier (not setState)
  // so a drag repaints ONLY the dock strip — rebuilding the whole sheet every
  // drag frame was a measured build-time stall.
  final ValueNotifier<double> _expand = ValueNotifier<double>(0);

  /// Lets something OTHER than a drag open the sheet. A swipe is the only way
  /// up on a phone and needs nothing else; on a desktop there is no finger, and
  /// dragging a sheet with a mouse is a discoverability dead end — so the dock
  /// carries an all-apps button there, and this is what it drives.
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// True where the user has no touch gestures to reach the grid with.
  bool get _needsAllAppsButton =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  void _openAllApps() => _animateTo(1);

  /// Tap the handle to toggle. Opening the grid on a desktop was only half the
  /// problem: a mouse drag on the handle does not carry the sheet back down the
  /// way a finger does, so without this the grid opens and never closes.
  void _toggle(double peek) =>
      _animateTo(_sheet.isAttached && _sheet.size > peek + 0.02 ? peek : 1);

  void _animateTo(double extent) {
    if (!_sheet.isAttached) return;
    _sheet.animateTo(
      extent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _expand.dispose();
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The system navigation bar sits ON TOP of the sheet (the launcher draws
    // edge to edge). On a phone with a gesture/3-button bar — the C61 has one,
    // the TANK2 doesn't — it lands right across the dock and the drag handle,
    // so the user is fighting the system bar to lift the sheet. Reserve its
    // height: the peek grows by it, and the peek's content is padded above it.
    final navBar = MediaQuery.viewPaddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final peek = constraints.maxHeight <= 0
            ? 0.14
            : ((_peekPx + navBar) / constraints.maxHeight).clamp(0.08, 0.5);
        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (n) {
            _expand.value =
                ((n.extent - peek) / (0.45 - peek)).clamp(0.0, 1.0);
            return false;
          },
          child: DraggableScrollableSheet(
            controller: _sheet,
            minChildSize: peek,
            initialChildSize: peek,
            maxChildSize: 1,
            snap: true,
            snapSizes: [peek, 1],
            builder: (context, controller) {
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.16),
                      blurRadius: 24,
                      offset: const Offset(0, -6),
                    ),
                  ],
                ),
                child: CustomScrollView(
                  controller: controller,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          // 10 + 5 + 8 of the peek budget, spent as one
                          // full-width tap target instead of three widgets —
                          // the bare 42x5 pill was far too small to click.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _toggle(peek),
                            child: SizedBox(
                              height: 23,
                              width: double.infinity,
                              child: Center(
                                child: Container(
                                  width: 42,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: cs.outlineVariant,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // The dock collapses away as the sheet opens — its
                          // wapps are already in the grid below. Only this
                          // strip rebuilds while the sheet is dragged.
                          ValueListenableBuilder<double>(
                            valueListenable: _expand,
                            builder: (context, expand, child) {
                              if (expand >= 1) return const SizedBox.shrink();
                              return SizedBox(
                                height: (86 * (1 - expand)).clamp(0.0, 86.0),
                                child: Opacity(
                                  opacity: 1 - expand,
                                  child: OverflowBox(
                                    maxHeight: 86,
                                    alignment: Alignment.topCenter,
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: _QuickLaunchRow(
                              entries: entries,
                              onOpenAll:
                                  _needsAllAppsButton ? _openAllApps : null,
                            ),
                          ),
                          // Clear of the system navigation bar (see above).
                          SizedBox(height: 8 + navBar),
                        ],
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 32 + navBar),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 120,
                              mainAxisSpacing: 20,
                              crossAxisSpacing: 20,
                            ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final e = entries[index];
                          return _AppIcon(
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
                          );
                        }, childCount: entries.length),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
