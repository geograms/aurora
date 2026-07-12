import 'hero_item.dart';

/// A contributor to the launcher hero.
///
/// A source only ever *offers* candidates — it never decides what is shown.
/// Ranking, per-author caps and the per-source slot budget all live in
/// [rankHero] (hero_ranker.dart), so a new source cannot elbow the others out
/// just by returning more items.
abstract class HeroSource {
  /// Matches [HeroItem.sourceId] of everything this source yields.
  String get id;

  /// Called once per refresh (every 5 minutes, and only while the launcher is
  /// on screen). Must be cheap and must not block: no network round-trip on the
  /// calling isolate, no unbounded work. Draining a buffer is the model.
  Future<List<HeroItem>> candidates();
}
