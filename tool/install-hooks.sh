#!/usr/bin/env bash
# Install the repo's git hooks (opt-in, per clone — git does not ship hooks).
#
# The pre-commit hook runs tool/arch_guard.dart on the staged tree. It is fast
# (a regex sweep over lib/, no analyzer, no pub get) and only fails on a NEW
# violation, so it stays out of the way until it has something to say.
#
#   ./tool/install-hooks.sh          install
#   ./tool/install-hooks.sh --off    remove
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hook="$root/.git/hooks/pre-commit"

if [ "${1:-}" = "--off" ]; then
  rm -f "$hook"
  echo "pre-commit hook removed"
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
echo "pre-commit hook installed -> $hook"
echo "run 'dart tool/arch_guard.dart --list' to see what it knows about"
