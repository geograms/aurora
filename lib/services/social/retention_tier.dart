/*
 * Pure tier classification for the store-and-forward host. Decides whether a
 * piece of content (a note or a file) belongs to us, to someone we follow, or to
 * a stranger — which drives retention/quota (see host_retention_policy.dart). No
 * Flutter/IO deps so it is unit-testable headlessly.
 *
 *   self     = authored by our own pubkey -> never deleted, no quota.
 *   followed = authored by a pubkey we follow (bridged from callsign follows) ->
 *              text kept; media evictable only under storage pressure.
 *   stranger = everyone else -> capped + retention-limited.
 */

enum Tier { self, followed, stranger }

/// Classify the author [authorPubHex] (64-char lowercase hex). [selfPubHex] is
/// our own pubkey (null when no profile key yet); [followsHex] is the set of
/// pubkeys we follow, as lowercase hex.
Tier tierOf(
  String authorPubHex, {
  required String? selfPubHex,
  required Set<String> followsHex,
}) {
  final a = authorPubHex.toLowerCase();
  if (selfPubHex != null && a == selfPubHex.toLowerCase()) return Tier.self;
  if (followsHex.contains(a)) return Tier.followed;
  return Tier.stranger;
}
