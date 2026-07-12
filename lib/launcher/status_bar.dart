part of 'launcher.dart';

/// The fourth rectangle on the home screen: not a wapp, but the answer to
/// "is any of this actually working?".
///
/// A mesh app's most common question is who it can reach and whether the network
/// is doing anything — and until now the only honest answer was to open the
/// Reticulum wapp and read a graph. This puts the numbers where they are seen
/// without being asked: how many devices are reachable and over what, what the
/// mesh is carrying, and how much of the social feed is people you chose.
///
/// It polls, so it is gated on [LauncherVisibility]: a status line nobody is
/// looking at is a battery bill (docs/performance.md §6.5).
class _StatusBar extends StatefulWidget {
  /// Opens the wapp that can explain the numbers (the launcher owns routing).
  final VoidCallback? onTap;

  const _StatusBar({this.onTap});

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  static const Duration _every = Duration(seconds: 5);

  Timer? _timer;
  _NetStats _stats = const _NetStats();

  @override
  void initState() {
    super.initState();
    LauncherVisibility.instance.visible.addListener(_onVisibility);
    _onVisibility();
  }

  @override
  void dispose() {
    _timer?.cancel();
    LauncherVisibility.instance.visible.removeListener(_onVisibility);
    super.dispose();
  }

  void _onVisibility() {
    if (!LauncherVisibility.instance.visible.value) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    _sample();
    _timer = Timer.periodic(_every, (_) => _sample());
  }

  /// Everything here is an in-memory read except the two post counts, which are
  /// indexed sqlite COUNTs on a store this isolate already owns. Cheap enough
  /// for a 5-second tick; anything heavier belongs behind a tap, not on the
  /// home screen.
  void _sample() {
    final rns = RnsService.instance;
    final follows = rns.follows.asSet.toList();
    final total = rns.nostrPostCount();
    final followed =
        follows.isEmpty ? 0 : rns.nostrPostCount(authors: follows);

    final next = _NetStats(
      up: rns.isUp,
      devices: rns.reachableDevices,
      hubs: rns.connectedHubs.length,
      bleNeighbours: MeshService.instance.table?.neighbors.length ?? 0,
      paths: rns.pathCount,
      follows: follows.length,
      followedPosts: followed,
      totalPosts: total,
    );
    if (mounted && next != _stats) setState(() => _stats = next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _stats;
    const accent = _heroGreen;
    final live = s.up && (s.devices > 0 || s.hubs > 0 || s.bleNeighbours > 0);

    return Material(
      color: Color.alphaBlend(accent.withValues(alpha: 0.10), cs.surface),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // Tapping it opens the wapp that can actually explain the numbers.
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accent.withValues(alpha: live ? 0.5 : 0.22),
              width: 1.2,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: live ? 0.18 : 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  live ? Icons.lan : Icons.lan_outlined,
                  color: live ? accent : cs.onSurfaceVariant,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Shrink rather than ellipsize: "4 hubs · 38 paths · 867/1…"
                    // tells the user less than the same line one point smaller.
                    // Phone font scales are larger than the desktop's, and this
                    // line is the one that grows with the numbers in it.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        s.detail,
                        maxLines: 1,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
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

/// A snapshot of "is the network alive", cheap to compare so an unchanged tick
/// never rebuilds the bar.
class _NetStats {
  final bool up;
  final int devices; // geogram devices reachable right now (any transport)
  final int hubs; // internet uplinks we hold
  final int bleNeighbours; // BLE mesh neighbours heard
  final int paths; // Reticulum path table size — the mesh we can see
  final int follows;
  final int followedPosts;
  final int totalPosts;

  const _NetStats({
    this.up = false,
    this.devices = 0,
    this.hubs = 0,
    this.bleNeighbours = 0,
    this.paths = 0,
    this.follows = 0,
    this.followedPosts = 0,
    this.totalPosts = 0,
  });

  /// Who we can reach, and how. The transports are named because on a mesh they
  /// are not interchangeable: an internet hub and a Bluetooth neighbour mean
  /// very different things about where you are.
  String get headline {
    if (!up) return 'Reticulum is off';
    final parts = <String>[];
    if (devices > 0) {
      parts.add('$devices ${devices == 1 ? 'device' : 'devices'} reachable');
    }
    if (bleNeighbours > 0) parts.add('$bleNeighbours over Bluetooth');
    if (parts.isEmpty) {
      return hubs > 0 ? 'On the network, nobody around yet' : 'Looking for a way out';
    }
    return parts.join(' · ');
  }

  /// What the network is carrying. Posts from people you follow are called out
  /// separately from the total, because the difference between "the feed is
  /// busy" and "the people I chose are busy" is the whole point of following.
  /// Kept SHORT on purpose: this is one line on a phone, and a sentence that
  /// ellipsizes tells the user less than three numbers that fit.
  String get detail {
    final bits = <String>[];
    if (hubs > 0) bits.add('$hubs ${hubs == 1 ? 'hub' : 'hubs'}');
    if (paths > 0) bits.add('$paths ${paths == 1 ? 'path' : 'paths'}');
    if (totalPosts > 0) {
      bits.add(follows > 0
          ? '${_n(followedPosts)}/${_n(totalPosts)} followed'
          : '${_n(totalPosts)} posts');
    }
    return bits.isEmpty ? 'No traffic yet' : bits.join(' · ');
  }

  static String _n(int v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';

  @override
  bool operator ==(Object other) =>
      other is _NetStats &&
      other.up == up &&
      other.devices == devices &&
      other.hubs == hubs &&
      other.bleNeighbours == bleNeighbours &&
      other.paths == paths &&
      other.follows == follows &&
      other.followedPosts == followedPosts &&
      other.totalPosts == totalPosts;

  @override
  int get hashCode => Object.hash(
      up, devices, hubs, bleNeighbours, paths, follows, followedPosts, totalPosts);
}
