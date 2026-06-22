#!/usr/bin/env bash
# =============================================================================
# release.sh — cut a Geogram Aurora release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, commits, tags vX.Y.Z and pushes.
# The release workflow (.github/workflows/release.yml) then builds the Android
# APK, Linux tar.gz and Windows installer named aurora-<version>-<platform>.
# Updates are decentralized: the built artifacts are published into the two
# signed Reticulum update folders on the always-on node (see
# tool/publish_update_folder.sh) — no central web host. The in-app Update Center
# fetches them peer-to-peer over Reticulum and verifies each by sha256.
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

# Pushing the tag triggers .github/workflows/release.yml, which builds the three
# aurora-<version>-<platform> artifacts. Publish them into the signed Reticulum
# update folders on the always-on node (the master keys live only in each
# .folder.json there — no CI secret):
#
#   AURORA_API=http://<node>:3456 \
#     tool/publish_update_folder.sh ${VERSION} <dir-with-built-artifacts>
#
# That copies the binaries into the beta folder (and the stable folder for a
# non-prerelease) and rescans, so the node signs the addFile ops and serves the
# bytes. Consumers fetch them over Reticulum and re-seed — no central web host.
echo ">> done. release.yml is building v${VERSION}'s artifacts."
echo ">>   then on the always-on node, publish them to the update folders:"
echo ">>     tool/publish_update_folder.sh ${VERSION} <artifacts-dir>"
