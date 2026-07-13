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
              height: 196,
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
      height: 196,
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

  /// Backdrop for a post that brings no picture (and the placeholder under one
  /// that is still loading).
  ///
  /// A flat gradient over half the carousel looked like the app had failed to
  /// load something. So the gradient gets a quiet generated texture on top —
  /// arcs and dots seeded from the post's own id, so a given post always draws
  /// the same pattern and the card doesn't shimmer between refreshes. It is
  /// deliberately low-contrast: this is wallpaper behind text, not decoration
  /// competing with it.
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
    child: CustomPaint(
      painter: _HeroPatternPainter(seed: item.id.hashCode, accent: _accent),
      // A painter with no child paints nothing unless it is told how big it is.
      child: const SizedBox.expand(),
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
              // Chips and text in ONE column, not two Positioned layers that
              // both float free: the title is pinned to the bottom and grows
              // UPWARD, so a two-line headline drew straight over the author
              // chip and hid whose post it was. A column cannot overlap
              // itself — the text gets the space the chips do not use.
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                      const SizedBox(height: 12),
                      // The headline starts directly under the chips and takes
                      // everything below them. Bottom-anchoring it (what this
                      // used to do) left a dead band across the top of every
                      // short post, and squeezed the title into a stub while
                      // the summary took the room.
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            // Only the last lines can reach the likes pill, so
                            // the inset is on the bottom of the block, not the
                            // whole width of the headline.
                            padding: const EdgeInsets.only(bottom: 2),
                            child: _TextBlock(
                              item: item,
                              accent: _accent,
                              // The likes/replies pill sits in the bottom-right
                              // corner; the summary must not run under it.
                              reserveCorner:
                                  item.likes > 0 || item.replies > 0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
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

/// The quiet texture behind a picture-less hero card.
///
/// Everything is derived from one integer seed (the post's id hash), so the same
/// post always gets the same pattern — a card that redrew a different texture on
/// every refresh would flicker under the user's eyes. No randomness at paint
/// time, and no state: [shouldRepaint] is false because nothing here can change.
class _HeroPatternPainter extends CustomPainter {
  final int seed;
  final Color accent;

  const _HeroPatternPainter({required this.seed, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);

    // Two big soft arcs sweeping across the card. Low alpha, wide stroke: they
    // read as light falling on a surface, not as shapes.
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 2; i++) {
      final r = size.width * (0.45 + rnd.nextDouble() * 0.45);
      final cx = size.width * (rnd.nextDouble() * 1.2 - 0.1);
      final cy = size.height * (rnd.nextDouble() * 1.4 - 0.2);
      arc
        ..strokeWidth = 10 + rnd.nextDouble() * 26
        ..color = Colors.white.withValues(alpha: 0.045 + rnd.nextDouble() * 0.03);
      canvas.drawCircle(Offset(cx, cy), r, arc);
    }

    // A scatter of dots, denser toward the top-right (the corner the text never
    // occupies), thinning out where the title and summary will land.
    final dot = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 26; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      // Fade the dot out as it approaches the lower-left text zone.
      final textZone = (1 - x / size.width) * (y / size.height);
      final alpha = (0.10 - textZone * 0.09).clamp(0.012, 0.10);
      dot.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), 1.2 + rnd.nextDouble() * 2.6, dot);
    }

    // One accent-tinted glow in a corner, so cards of different colours don't
    // all look like the same grey texture.
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [accent.withValues(alpha: 0.22), accent.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * (0.72 + rnd.nextDouble() * 0.2),
            size.height * (rnd.nextDouble() * 0.35)),
        radius: size.width * 0.42,
      ));
    canvas.drawRect(Offset.zero & size, glow);
  }

  @override
  bool shouldRepaint(covariant _HeroPatternPainter old) =>
      old.seed != seed || old.accent != accent;
}

/// Title + summary, with a plate behind them when the photo underneath is pale.
///
/// White bold text over a photo is fine until the photo is a snow field or an
/// overexposed sky, and then the headline simply disappears. The bottom scrim
/// cannot be made dark enough to fix that case without dimming every other card
/// into mud. So the card MEASURES the image where the text actually sits
/// (HeroBrightness — a 32px decode, once per item, cached) and puts a soft dark
/// plate behind the words only when it needs to.
class _TextBlock extends StatelessWidget {
  final HeroItem item;
  final Color accent;

  /// Keep the bottom-right corner clear for the likes/replies pill.
  final bool reserveCorner;

  const _TextBlock({
    required this.item,
    required this.accent,
    this.reserveCorner = false,
  });

  @override
  Widget build(BuildContext context) {
    // Cheap and de-duplicated: the first build of a card starts the measurement,
    // and the notifier below rebuilds just this block when the verdict lands.
    HeroBrightness.instance.probe(item);

    return ValueListenableBuilder<int>(
      valueListenable: HeroBrightness.instance.revision,
      builder: (context, _, __) {
        final bright = HeroBrightness.instance.verdictFor(item) ?? false;
        // The headline is what the card is FOR, so it is served first: up to
        // three lines of it, and the summary only gets what is left over —
        // measured, not guessed. The old fixed 2+2 split cut a headline to a
        // stub ("The no-l bake") while the summary below it ran on, and on a
        // narrow phone that reads as a broken card.
        final text = LayoutBuilder(
          builder: (context, box) {
            const titleStyle = TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.18,
              shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
            );
            final summaryStyle = TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 13,
              height: 1.3,
            );

            // How tall the headline actually is at this width, capped at three
            // lines. Everything below it belongs to the summary — if two lines
            // of it fit, it gets two; if one fits, one; if none, none.
            final painter = TextPainter(
              text: TextSpan(text: item.title, style: titleStyle),
              maxLines: 3,
              textDirection: Directionality.of(context),
            )..layout(maxWidth: box.maxWidth);
            final titleHeight = painter.height;

            const gap = 6.0;
            final summaryLine = summaryStyle.fontSize! * summaryStyle.height!;
            final leftOver = box.maxHeight - titleHeight - gap;
            final summaryLines = (leftOver / summaryLine).floor().clamp(0, 2);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (item.summary.isNotEmpty && summaryLines > 0) ...[
                  const SizedBox(height: gap),
                  Padding(
                    padding: EdgeInsets.only(right: reserveCorner ? 86 : 0),
                    child: Text(
                      item.summary,
                      maxLines: summaryLines,
                      overflow: TextOverflow.ellipsis,
                      style: summaryStyle,
                    ),
                  ),
                ],
              ],
            );
          },
        );

        if (!bright) return text;

        // The plate. Rounded and slightly inset so it reads as a label on the
        // photo rather than a bug — and translucent, so the picture is still
        // visible through it.
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            child: text,
          ),
        );
      },
    );
  }
}
