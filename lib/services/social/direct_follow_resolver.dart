Set<String> resolveDirectFollows({
  required Iterable<String> contactSnapshot,
  required Iterable<String> localFollows,
  required Iterable<String> explicitUnfollows,
}) {
  final unfollowed = {for (final key in explicitUnfollows) key.toLowerCase()};
  return {
    for (final key in [...contactSnapshot, ...localFollows])
      if (key.length == 64 && !unfollowed.contains(key.toLowerCase()))
        key.toLowerCase(),
  };
}
