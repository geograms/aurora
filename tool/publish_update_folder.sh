#!/usr/bin/env bash
# =============================================================================
# publish_update_folder.sh — publish a built release into the signed Reticulum
# update folders, on the always-on publisher node.
#
# Aurora updates are decentralized: the publisher owns two signed mutable
# folders (an IPNS-like, secp256k1-signed content-addressed store) served from
# disk by the always-on node — one per channel:
#   stable  ($AURORA_UPDATE_DIR_STABLE)  only non-prerelease builds
#   beta    ($AURORA_UPDATE_DIR_BETA)    every build
# Each per-platform binary is named  aurora-<version>-<platform>  so the app can
# parse the version and pick the right artifact (see update_models.dart). This
# script copies a version's artifacts into the right watched dir(s) and asks the
# local node to rescan, which signs the addFile ops and starts serving the bytes
# over Reticulum. No central web host; consumers re-seed what they download.
#
# One-time setup on the always-on node (creates each .folder.json master key —
# back these up, never commit them; the returned folderId is the npub to pin):
#   curl -s -XPOST $API/api/rns/folder/adddisk -d '{"path":"/srv/aurora-updates-stable"}'
#   curl -s -XPOST $API/api/rns/folder/adddisk -d '{"path":"/srv/aurora-updates-beta"}'
# Bake the two folderIds into update_service.dart's
# defaultUpdateFolderStableNpub / ...BetaNpub.
#
# Usage:
#   publish_update_folder.sh <version> <artifacts-dir>
#     <version>        e.g. 1.0.4  or  1.0.4-beta.2  (a '-' => beta only)
#     <artifacts-dir>  dir holding aurora-<version>-*.{apk,tar.gz,exe}
#
# Env (with defaults):
#   AURORA_UPDATE_DIR_STABLE=/srv/aurora-updates-stable
#   AURORA_UPDATE_DIR_BETA=/srv/aurora-updates-beta
#   AURORA_API=http://127.0.0.1:3456     (the always-on node's JSON API)
# =============================================================================
set -euo pipefail

VERSION="${1:-}"
ARTIFACTS="${2:-}"
if [[ -z "$VERSION" || -z "$ARTIFACTS" ]]; then
  echo "usage: publish_update_folder.sh <version> <artifacts-dir>" >&2
  exit 2
fi
if [[ ! -d "$ARTIFACTS" ]]; then
  echo "error: artifacts dir not found: $ARTIFACTS" >&2
  exit 2
fi

DIR_STABLE="${AURORA_UPDATE_DIR_STABLE:-/srv/aurora-updates-stable}"
DIR_BETA="${AURORA_UPDATE_DIR_BETA:-/srv/aurora-updates-beta}"
API="${AURORA_API:-http://127.0.0.1:3456}"

# A version with a '-' (1.0.4-beta.2, 1.0.4-rc.1) is a prerelease: beta only.
is_prerelease=0
[[ "$VERSION" == *-* ]] && is_prerelease=1

# Known per-platform suffixes, longest first, mirroring update_models.dart's
# versionFromAssetName so the bash side splits the version the exact same way.
SUFFIXES=(-linux-x64.tar.gz -setup.exe .apk .tar.gz .zip .exe .dmg)

# Parse the version out of an aurora-<version>-<platform> filename, or empty if
# it isn't a recognised aurora artifact.
version_of() {
  local base="$1" rest
  [[ "$base" == aurora-* ]] || { echo ""; return; }
  rest="${base#aurora-}"
  for suf in "${SUFFIXES[@]}"; do
    if [[ "$rest" == *"$suf" && "$rest" != "$suf" ]]; then
      echo "${rest%"$suf"}"; return
    fi
  done
  echo ""
}

# Collect only artifacts whose PARSED version equals exactly $VERSION (so
# publishing 1.0.4 never sweeps in 1.0.4-beta.2 or 1.0.40).
shopt -s nullglob
files=()
for f in "$ARTIFACTS"/aurora-*; do
  [[ -f "$f" ]] || continue
  [[ "$(version_of "$(basename "$f")")" == "$VERSION" ]] && files+=("$f")
done
shopt -u nullglob
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "error: no aurora-$VERSION artifacts in $ARTIFACTS" >&2
  exit 1
fi

copy_into() {
  local dest="$1"
  mkdir -p "$dest"
  for f in "${files[@]}"; do
    cp -f "$f" "$dest/$(basename "$f")"
    echo "   + $(basename "$f")  ->  $dest"
  done
}

echo ">> publishing aurora $VERSION (${#files[@]} artifact(s))"
echo ">> beta channel: $DIR_BETA"
copy_into "$DIR_BETA"
if [[ "$is_prerelease" -eq 0 ]]; then
  echo ">> stable channel: $DIR_STABLE"
  copy_into "$DIR_STABLE"
else
  echo ">> stable channel: skipped (prerelease)"
fi

# Ask the always-on node to rescan its owned disk folders. With no folderId it
# rescans them all; DiskFolderManager diffs each dir, signs addFile ops and
# advertises providers so peers can fetch the new bytes.
echo ">> rescanning owned folders via $API"
if command -v curl >/dev/null 2>&1; then
  curl -fsS -X POST "$API/api/rns/folder/rescan" \
    -H 'Content-Type: application/json' -d '{}' \
    && echo "" && echo ">> done — $VERSION is live on Reticulum." \
    || { echo "error: rescan request failed (is the node running on $API?)" >&2; exit 1; }
else
  echo "warn: curl not found — trigger the rescan yourself:" >&2
  echo "  POST $API/api/rns/folder/rescan  {}" >&2
fi
