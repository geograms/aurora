#!/usr/bin/env bash
# Install the repo's git hooks (opt-in, per clone — git does not ship hooks).
#
# pre-commit runs tool/arch_guard.dart on the staged tree. It is fast (a regex
# sweep over lib/, no analyzer, no pub get) and only fails on a NEW violation,
# so it stays out of the way until it has something to say.
#
# pre-push refuses a push while lib/, test/ or assets/ hold uncommitted work,
# and warns when the reticulum-dart sibling does. Both are pure git — the point
# is that CI compiles what you PUSHED, not what is on your disk, and the gap
# between the two is what turns a green local run into a red build.
#
#   ./tool/install-hooks.sh          install both
#   ./tool/install-hooks.sh --off    remove both
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/.git/hooks/pre-commit"
push_hook="$root/.git/hooks/pre-push"

if [ "${1:-}" = "--off" ]; then
  rm -f "$hook" "$push_hook"
  echo "pre-commit and pre-push hooks removed"
  exit 0
fi

mkdir -p "$root/.git/hooks"
cat > "$hook" <<'EOF'
#!/usr/bin/env bash
# Aurora architecture guard — see docs/architecture.md §5.
# Skip once with:  git commit --no-verify
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
if ! command -v dart >/dev/null 2>&1; then
  exit 0   # no Dart on this machine: CI will still check
fi
cd "$root"
dart tool/arch_guard.dart
EOF
chmod +x "$hook"

cat > "$push_hook" <<'EOF'
#!/usr/bin/env bash
# Aurora pre-push guard — see docs/architecture.md §5.
#
# CI compiles what you PUSHED. This machine compiles what is on your disk. When
# those differ, `flutter test` passing here proves nothing: a commit can name a
# symbol whose definition is still sitting unstaged, and the first thing to find
# out is the build. That has happened repeatedly, always the same way.
#
# Skip once with:  git push --no-verify
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"

# 1. Our own tree. Anything uncommitted under these paths is code CI will not
#    see, while every check you ran locally did see it.
dirty="$(git status --porcelain -- lib test assets 2>/dev/null || true)"
if [ -n "$dirty" ]; then
  echo "pre-push: uncommitted work under lib/, test/ or assets/ —"
  echo "          CI builds without it, so what you tested is not what you are pushing:"
  echo "$dirty" | sed 's/^/            /'
  echo
  echo "          Commit it, or push anyway with:  git push --no-verify"
  exit 1
fi

# 2. The sibling package. Aurora depends on ../reticulum-dart by path, so it
#    resolves to YOUR working tree here and to geograms/reticulum-dart@main in
#    CI. Anything uncommitted there exists for you and for nobody else. A
#    warning, not a refusal: unrelated work often sits in that repo.
sib="$root/../reticulum-dart"
if [ -d "$sib/.git" ]; then
  sib_dirty="$(git -C "$sib" status --porcelain -- lib 2>/dev/null || true)"
  if [ -n "$sib_dirty" ]; then
    echo "pre-push: WARNING ../reticulum-dart has uncommitted changes under lib/ —"
    echo "          CI clones that repo at main and will not see them:"
    echo "$sib_dirty" | sed 's/^/            /'
  fi
  if git -C "$sib" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    ahead="$(git -C "$sib" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" != "0" ]; then
      echo "pre-push: WARNING ../reticulum-dart is $ahead commit(s) ahead of its remote —"
      echo "          push that repo first, or CI resolves the older code."
    fi
  fi
fi
exit 0
EOF
chmod +x "$push_hook"

echo "pre-commit hook installed -> $hook"
echo "pre-push   hook installed -> $push_hook"
echo "run 'dart tool/arch_guard.dart --list' to see what the commit guard knows about"
