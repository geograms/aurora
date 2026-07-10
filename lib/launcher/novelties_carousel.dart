part of 'launcher.dart';

class _NoveltiesCarousel extends StatefulWidget {
  /// Tap on a hero card — opens the post in the social wapp.
  final void Function(NoveltyItem item)? onOpenItem;

  const _NoveltiesCarousel({this.onOpenItem});

  @override
  State<_NoveltiesCarousel> createState() => _NoveltiesCarouselState();
}

class _NoveltiesCarouselState extends State<_NoveltiesCarousel> {
  static const Duration _advanceEvery = Duration(seconds: 6);

  /// Start far from zero so the user can swipe "left of the first slide" and
  /// land on the last one — the page list is virtually infinite in both
  /// directions and every index maps onto the items with a modulo.
  static const int _basePage = 5000;

  final PageController _controller = PageController(
    viewportFraction: 0.9,
    initialPage: _basePage,
  );
  late final NoveltiesRefresher _refresher;
  Timer? _advance;
  int _page = _basePage;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _refresher = NoveltiesRefresher(NoveltiesService.instance.refresh)..start();
    _startAdvance();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _refresher.stop();
    _controller.dispose();
    super.dispose();
  }

  /// Rotate the hero on its own. Restarted whenever the user swipes, so a
  /// deliberate swipe is never yanked out from under them mid-read.
  void _startAdvance() {
    _advance?.cancel();
    _advance = Timer.periodic(_advanceEvery, (_) {
      if (!mounted || _count < 2 || !_controller.hasClients) return;
      // Raw page index — the page space is endless and wraps via modulo.
      _controller.animateToPage(
        _page + 1,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<NoveltyItem>>(
      valueListenable: NoveltiesService.instance.novelties,
      builder: (context, items, _) {
        if (items.isEmpty) return const _NoveltiesEmpty();
        _count = items.length;
        final activePage = (_page % items.length).abs();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 172,
              // A touch means the user is reading or swiping: hold the rotation
              // and give them a fresh interval once they let go.
              child: Listener(
                onPointerDown: (_) => _advance?.cancel(),
                onPointerUp: (_) => _startAdvance(),
                onPointerCancel: (_) => _startAdvance(),
                child: PageView.builder(
                  controller: _controller,
                  // No itemCount: virtually endless, so swiping left on the
                  // first slide wraps to the last (and vice versa).
                  onPageChanged: (value) => setState(() => _page = value),
                  itemBuilder: (context, index) {
                    final item = items[index % items.length];
                    return _NoveltyCard(
                      item: item,
                      onTap: widget.onOpenItem == null
                          ? null
                          : () => widget.onOpenItem!(item),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == activePage ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == activePage
                          ? _heroGreen
                          : Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _NoveltiesEmpty extends StatelessWidget {
  const _NoveltiesEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 172,
      margin: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            cs.primaryContainer.withValues(alpha: 0.65),
            cs.secondaryContainer.withValues(alpha: 0.45),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        RnsService.instance.isUp
            ? 'Listening for network activity...'
            : 'Start Reticulum to see network activity',
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
    );
  }
}

// The gnpa launcher palette — richer than the app's blue seed and what the
// hero cards and accents are tuned against.
const Color _heroGreen = Color(0xFF52C77E);
const Color _heroBlue = Color(0xFF4A90E2);
const Color _heroGold = Color(0xFFC79A3A);
const Color _heroViolet = Color(0xFF8E6FD8);
const List<Color> _heroAccents = [
  _heroGreen,
  _heroBlue,
  _heroGold,
  _heroViolet,
];

class _NoveltyCard extends StatelessWidget {
  final NoveltyItem item;
  final VoidCallback? onTap;

  const _NoveltyCard({required this.item, this.onTap});

  /// Stable per-post accent so a card keeps its colour across refreshes.
  Color get _accent =>
      _heroAccents[item.id.hashCode.abs() % _heroAccents.length];

  /// Gradient placeholder used when the post brings no picture (or while the
  /// network image is still loading / failed).
  Widget _gradientBackdrop() => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          _accent.withValues(alpha: 0.92),
          Color.lerp(_accent, Colors.black, 0.55)!,
          const Color(0xFF101216),
        ],
      ),
    ),
  );

  Widget _backdrop() {
    final url = item.imageUrl;
    final thumb = item.thumbnail;
    // Sharpest source first: full image over the network, the post's inline
    // tn: preview while it loads (or when the fetch fails), gradient last.
    final under = thumb != null
        ? Image.memory(thumb, fit: BoxFit.cover)
        : _gradientBackdrop();
    if (url == null) return under;
    return Stack(
      fit: StackFit.expand,
      children: [
        under,
        Image.network(
          url,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // Bound the decode: hero photos can be multi-megapixel, and decoding
          // one at full size mid-swipe drops frames. The card is ~screen-wide.
          cacheWidth: 1024,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : const SizedBox.shrink(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 0),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _backdrop(),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.10),
                      Colors.black.withValues(alpha: 0.78),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 18,
                top: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _accent.withValues(alpha: 0.55)),
                  ),
                  child: Text(
                    item.authorName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 96,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                    ),
                    if (item.summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (item.likes > 0 || item.replies > 0)
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.48),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.favorite,
                          size: 13,
                          color: Color(0xFFEF6D6D),
                        ),
                        const SizedBox(width: 4),
                        Text('${item.likes}', style: _statStyle),
                        if (item.replies > 0) ...[
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.mode_comment,
                            size: 12,
                            color: _heroBlue,
                          ),
                          const SizedBox(width: 4),
                          Text('${item.replies}', style: _statStyle),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const TextStyle _statStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );
}
