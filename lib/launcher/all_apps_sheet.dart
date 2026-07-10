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

  @override
  void dispose() {
    _expand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final peek = constraints.maxHeight <= 0
            ? 0.14
            : (_peekPx / constraints.maxHeight).clamp(0.08, 0.5);
        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (n) {
            _expand.value =
                ((n.extent - peek) / (0.45 - peek)).clamp(0.0, 1.0);
            return false;
          },
          child: DraggableScrollableSheet(
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
                          const SizedBox(height: 10),
                          Container(
                            width: 42,
                            height: 5,
                            decoration: BoxDecoration(
                              color: cs.outlineVariant,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          const SizedBox(height: 8),
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
                            child: _QuickLaunchRow(entries: entries),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
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
