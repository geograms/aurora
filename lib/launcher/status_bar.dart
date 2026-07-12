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
    final reach = rns.reachability();
    final prefs = PreferencesService.instanceSync;

    // "New" = posted by someone you follow since the last time you opened the
    // feed. A raw total ("871 of 17.4k") is a number nobody can act on; this one
    // tells you whether it is worth opening Social right now, and it goes down
    // when you read it.
    var since = prefs?.socialLastSeenMs ?? 0;
    if (since == 0 && prefs != null) {
      // First run: start counting from now. Without this the first reading would
      // be "17.4k new posts", which is true and useless.
      since = DateTime.now().millisecondsSinceEpoch;
      prefs.socialLastSeenMs = since;
    }
    final newPosts =
        follows.isEmpty ? 0 : rns.nostrNewPostCount(follows, since);

    final next = _NetStats(
      up: rns.isUp,
      devices: reach.geogram,
      others: reach.others,
      hubs: reach.hubs,
      bleNeighbours: MeshService.instance.table?.neighbors.length ?? 0,
      follows: follows.length,
      newPosts: newPosts,
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

/// Only numbers a person can act on.
///
/// Gone from here: the Reticulum path-table size. It is four figures, it moves
/// constantly, and there is nothing anyone can DO with it — engine telemetry
/// wearing a status bar's clothes. Gone too: "871/17.4k followed", which asked
/// the reader to work out what the ratio even meant.
class _NetStats {
  final bool up;
  final int devices; // GEOGRAM devices — the ones you can actually talk to
  final int others; // other Reticulum peers (Sideband/NomadNet) — context only
  final int hubs; // internet uplinks we hold
  final int bleNeighbours; // BLE mesh neighbours heard
  final int follows;
  final int newPosts; // from people you follow, since you last looked

  const _NetStats({
    this.up = false,
    this.devices = 0,
    this.others = 0,
    this.hubs = 0,
    this.bleNeighbours = 0,
    this.follows = 0,
    this.newPosts = 0,
  });

  /// Who we can reach. It says "geogram devices" explicitly, because the number
  /// people compare this against — the Reticulum wapp's badge — counts a
  /// different population (every LXMF peer heard on the hubs). The two looked
  /// like they contradicted each other while both just said "devices".
  String get headline {
    if (!up) return 'Reticulum is off';
    final parts = <String>[];
    if (devices > 0) {
      parts.add('$devices geogram ${devices == 1 ? 'device' : 'devices'}');
    }
    if (bleNeighbours > 0) parts.add('$bleNeighbours over Bluetooth');
    if (parts.isEmpty) {
      return hubs > 0
          ? 'On the network, no geogram devices yet'
          : 'Looking for a way out';
    }
    return parts.join(' · ');
  }

  /// One line on a phone: the things worth knowing, in the order they matter.
  String get detail {
    final bits = <String>[];
    if (newPosts > 0) {
      bits.add('${_n(newPosts)} new ${newPosts == 1 ? 'post' : 'posts'}');
    }
    if (hubs > 0) bits.add('$hubs ${hubs == 1 ? 'hub' : 'hubs'}');
    if (others > 0) bits.add('${_n(others)} other peers');
    if (bits.isEmpty) {
      return follows == 0
          ? 'Follow someone to see their posts here'
          : 'All quiet';
    }
    return bits.join(' · ');
  }

  static String _n(int v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';

  @override
  bool operator ==(Object other) =>
      other is _NetStats &&
      other.up == up &&
      other.devices == devices &&
      other.others == others &&
      other.hubs == hubs &&
      other.bleNeighbours == bleNeighbours &&
      other.follows == follows &&
      other.newPosts == newPosts;

  @override
  int get hashCode =>
      Object.hash(up, devices, others, hubs, bleNeighbours, follows, newPosts);
}
