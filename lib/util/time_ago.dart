/// Human label for a moment in the past.
///
/// Within two days it is a RELATIVE age ("just now", "19 minutes ago", "3 hours
/// ago", "yesterday"); older than that it becomes an absolute date ("Jun 26",
/// and with the year once it is not this year).
///
/// Extracted from the activity feed's label so the launcher hero and the feed
/// word time the same way — there were six near-identical formatters in the tree
/// and this is the one that spells the unit out.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// [now] is injectable so the boundaries can be tested without sleeping.
String timeAgo(DateTime dt, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(dt);
  final secs = diff.inSeconds;
  // Future-skew: the author's clock (or ours) is wrong. Don't say "in 3 hours".
  if (secs < -60) return 'now';
  if (secs < 45) return 'just now';
  final mins = diff.inMinutes;
  if (mins < 60) return '$mins minute${mins == 1 ? '' : 's'} ago';
  final hours = diff.inHours;
  if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'} ago';
  final days = diff.inDays;
  if (days < 2) return 'yesterday';
  final mon = _months[dt.month - 1];
  return dt.year == ref.year ? '$mon ${dt.day}' : '$mon ${dt.day} ${dt.year}';
}
