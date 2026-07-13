import 'hero_item.dart';
import 'hero_source.dart';

/// The hero on a brand-new install.
///
/// Every other source needs the network: NOSTR posts have to be relayed to us,
/// wapp items have to be published by a wapp that has run. On a fresh install
/// none of that has happened yet, so the carousel sat on its "nothing here"
/// card for minutes — the first thing a new user sees, and it reads as a broken
/// app.
///
/// So the hero starts with something to do. These cards are local, instant, and
/// they get out of the way the moment any real item arrives: [HeroFeedService]
/// only asks this source for candidates while everything else came back empty.
class WelcomeHeroSource implements HeroSource {
  @override
  String get id => kHeroSourceWelcome;

  /// Fixed timestamps would age these cards out of the ranker; they are always
  /// "now" so they hold the carousel until real posts displace them.
  @override
  Future<List<HeroItem>> candidates() async {
    final now = DateTime.now();
    return [
      _card(
        'welcome',
        'Welcome to Geogram',
        'Messaging that works over Bluetooth, the mesh and the internet — '
            'no account, no phone number.',
        now,
        intent: null,
      ),
      _card(
        'follow',
        'Follow someone in Social',
        'Their posts land right here, in this banner, as soon as the mesh '
            'relays them.',
        now.subtract(const Duration(seconds: 1)),
        intent: 'social',
      ),
      _card(
        'chat',
        'Say hello in Chat',
        'Encrypted messages to anyone nearby over Bluetooth, or across the '
            'world over Reticulum.',
        now.subtract(const Duration(seconds: 2)),
        intent: 'chat',
      ),
    ];
  }

  HeroItem _card(
    String key,
    String title,
    String summary,
    DateTime createdAt, {
    String? intent,
  }) =>
      HeroItem(
        id: '$kHeroSourceWelcome:$key',
        sourceId: kHeroSourceWelcome,
        title: title,
        summary: summary,
        createdAt: createdAt,
        authorName: 'Geogram',
        intent: intent,
      );
}

const String kHeroSourceWelcome = 'welcome';
