#!/usr/bin/env bash
# =============================================================================
# release.sh — cut a Geogram Aurora release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, commits, tags vX.Y.Z and pushes.
# The release workflow (.github/workflows/release.yml) then builds the Android
# APK, Linux tar.gz and Windows installer and PUBLISHES them to the self-hosted
# update feed at geogram.radio (the geograms/geogram-html repo), which the
# in-app Update Center reads — no github.com runtime dependency.
#
# Usage:
#   ./release.sh                 # auto-bump patch (or prerelease counter)
#   ./release.sh 1.2.0           # stable release
#   ./release.sh 1.2.0-beta.1    # beta (pre-release; shows in the beta channel)
#   ./release.sh 1.2.0 -y        # skip confirmation
# =============================================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YES=0
VERSION=""
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) VERSION="$a" ;;
  esac
done

current=$(grep '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | cut -d+ -f1)

# Auto-bump if no version given.
if [[ -z "$VERSION" ]]; then
  if [[ "$current" == *-* ]]; then
    base="${current%-*}"; label="${current##*-}"
    name="${label%.*}"; num="${label##*.}"
    VERSION="${base}-${name}.$((num + 1))"
  else
    IFS=. read -r MA MI PA <<<"$current"
    VERSION="${MA}.${MI}.$((PA + 1))"
  fi
fi

# Validate: X.Y.Z or X.Y.Z-(alpha|beta|rc).N
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo "error: invalid version '$VERSION' (use X.Y.Z or X.Y.Z-beta.N)"; exit 1
fi

CODE=$(git rev-list --count HEAD)
echo ">> current: $current   new: $VERSION+$CODE"
if [[ "$YES" -ne 1 ]]; then
  read -r -p ">> proceed? [y/N] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

sed -i "s/^version:.*/version: ${VERSION}+${CODE}/" pubspec.yaml
dart run tool/update_version.dart

git add pubspec.yaml lib/version.dart
git commit -m "Release v${VERSION}"
git tag "v${VERSION}"

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch"
git push origin "v${VERSION}"

# Pushing the tag triggers .github/workflows/release.yml, which builds the
# three platform artifacts and commits the update feed into THIS repo's
# updates/ folder (no secrets — uses the automatic GITHUB_TOKEN). The website
# repo's sync workflow then mirrors updates/ into geogram.radio/updates, and
# the in-app updater sees the new release on its next check.
echo ">> done. release.yml is building + publishing v${VERSION}'s feed to updates/."
echo ">>   geogram.radio mirrors it on its next sync (or trigger sync manually)."
echo ">>   (to publish manually instead, build the artifacts then run:"
echo ">>    dart run tool/publish_release.dart --site . --version ${VERSION} <files...>)"
