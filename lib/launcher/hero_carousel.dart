part of 'launcher.dart';

class _HeroCarousel extends StatefulWidget {
  /// Tap on a hero card — opens it in the wapp that published it.
  final void Function(HeroItem item)? onOpenItem;

  const _HeroCarousel({this.onOpenItem});

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  static const Duration _advanceEvery = Duration(seconds: 6);

  /// Start far from zero so the user can swipe "left of the first slide" and
  /// land on the last one — the page list is virtually infinite in both
  /// directions and every index maps onto the items with a modulo.
  static const int _basePage = 5000;

  final PageController _controller = PageController(
    viewportFraction: 0.9,
    initialPage: _basePage,
  );
  late final HeroRefresher _refresher;
  Timer? _advance;
  int _page = _basePage;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _refresher = HeroRefresher(HeroFeedService.instance.refresh)..start();
    LauncherVisibility.instance.visible.addListener(_onVisibility);
    _onVisibility();
  }

  @override
  void dispose() {
    _advance?.cancel();
    LauncherVisibility.instance.visible.removeListener(_onVisibility);
    _refresher.stop();
    _controller.dispose();
    super.dispose();
  }

  /// Animating a PageView nobody is looking at is pure waste — it keeps the
  /// raster thread awake behind a wapp page. Stop when hidden, resume when the
  /// launcher comes back (docs/performance.md §6.3).
  void _onVisibility() {
    if (LauncherVisibility.instance.visible.value) {
      _startAdvance();
    } else {
      _advance?.cancel();
      _advance = null;
    }
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
    return ValueListenableBuilder<List<HeroItem>>(
      valueListenable: HeroFeedService.instance.items,
      builder: (context, items, _) {
        if (items.isEmpty) return const _HeroEmpty();
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
                onPointerUp: (_) => _onVisibility(),
                onPointerCancel: (_) => _onVisibility(),
                child: PageView.builder(
                  controller: _controller,
                  // No itemCount: virtually endless, so swiping left on the
                  // first slide wraps to the last (and vice versa).
                  onPageChanged: (value) => setState(() => _page = value),
                  itemBuilder: (context, index) {
                    final item = items[index % items.length];
                    return _HeroCard(
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

/// What the hero shows before it has anything to show.
///
/// This is the first thing a new user sees, so it is a card in its own right —
/// not a grey box with an apology in it. The old one said "Start Reticulum to
/// see network activity" even while Reticulum was running, which reads as a
/// broken app rather than an empty one.
class _HeroEmpty extends StatelessWidget {
  const _HeroEmpty();

  @override
  Widget build(BuildContext context) {
    final up = RnsService.instance.isUp;
    final hasFollows = RnsService.instance.follows.asSet.isNotEmpty;

    final (IconData icon, String title, String body) = !up
        ? (
            Icons.hub_outlined,
            'The mesh is asleep',
            'Start Reticulum and the news people are posting will land here.',
          )
        : hasFollows
            ? (
                Icons.podcasts,
                'Listening',
                'Nothing new from the people you follow just yet.',
              )
            : (
                Icons.auto_awesome,
                'Finding what people are reading',
                'Follow someone in Social and their posts land here first.',
              );

    return Container(
      height: 172,
      margin: const EdgeInsets.fromLTRB(6, 18, 6, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2A4A), Color(0xFF16233B), Color(0xFF0C0C0F)],
        ),
        border: Border.all(color: _heroBlue.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _heroBlue.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: _heroBlue, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
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

class _HeroCard extends StatelessWidget {
  final HeroItem item;
  final VoidCallback? onTap;

  const _HeroCard({required this.item, this.onTap});

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
    // Sharpest source first: the full image, the post's inline tn: preview while
    // it loads (or when the fetch fails), gradient last.
    final under = thumb != null
        ? Image.memory(thumb, fit: BoxFit.cover)
        : _gradientBackdrop();
    if (url == null) return under;

    // A followed author's picture we have already mirrored into the archive:
    // render it from disk — instant, and it works with no network at all.
    if (FollowedMediaCache.isLocal(url)) {
      final bytes = sharedMediaArchive()?.get(url);
      if (bytes == null) return under;
      return Stack(
        fit: StackFit.expand,
        children: [
          under,
          // Bounded decode, exactly like the network branch: Flutter's image
          // cache is capped to 32MB/100 on mobile (main.dart), and a full-res
          // local decode would evict the whole thing on every swipe.
          Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 1024,
              gaplessPlayback: true),
        ],
      );
    }

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

  /// The readability scrim.
  ///
  /// A flat top-to-bottom wash (what this used to be) has to choose between
  /// dimming the whole photo and leaving the summary unreadable — over a bright
  /// picture it managed both. This is bottom-anchored instead: the top half of
  /// the image is untouched, and the fade ramps to near-black under the text.
  /// The intermediate stops are what make it read as a smooth transition rather
  /// than a visible band across the card.
  Widget _scrim() => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.42, 0.62, 0.80, 1.0],
        colors: [
          Colors.transparent,
          Color(0x1A000000), // 0.10
          Color(0x73000000), // 0.45
          Color(0xD1000000), // 0.82
          Color(0xF5000000), // 0.96
        ],
      ),
    ),
  );

  /// A light wash under the top chips, so the author name and the timestamp
  /// stay legible on a photo that is white up there.
  Widget _topScrim() => const Align(
    alignment: Alignment.topCenter,
    child: FractionallySizedBox(
      heightFactor: 0.32,
      widthFactor: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x47000000), Colors.transparent],
          ),
        ),
      ),
    ),
  );

  Widget _chip(Widget child, {Color? border}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(999),
      border: border == null ? null : Border.all(color: border),
    ),
    child: child,
  );

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
              _topScrim(),
              _scrim(),
              Positioned(
                left: 18,
                right: 18,
                top: 16,
                child: Row(
                  children: [
                    Flexible(
                      child: _chip(
                        Text(
                          item.authorName.isEmpty
                              ? item.sourceId
                              : item.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        border: _accent.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // When it happened. The hero shows posts that may be hours
                    // old (a quiet timeline is backfilled from the local
                    // mirror), so "19 minutes ago" vs "yesterday" is the
                    // difference between news and history.
                    _chip(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.schedule,
                              size: 11, color: Colors.white70),
                          const SizedBox(width: 4),
                          Text(
                            timeAgo(item.createdAt),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
                        // Belt and braces for the pathological all-white photo.
                        shadows: [
                          Shadow(blurRadius: 6, color: Colors.black54),
                        ],
                      ),
                    ),
                    if (item.summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.90),
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
