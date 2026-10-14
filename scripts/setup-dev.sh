#!/usr/bin/env bash
# One-time setup for a clone: use the repo's versioned git hooks.
#   pre-commit  -> scripts/check-staged.sh (whitespace, tabs, secret/personal-data shapes)
#   commit-msg  -> Conventional Commits subject check
#   pre-push    -> scripts/check.sh (forbidden patterns + swift build + swift test)
set -euo pipefail
cd "$(dirname "$0")/.."
chmod +x .githooks/* scripts/check-staged.sh
git config core.hooksPath .githooks
echo "✔ git hooks enabled (core.hooksPath=.githooks)"
deny="$(git rev-parse --git-path info/pii-denylist)"
if [[ ! -f "$deny" ]]; then
  printf '# One term per line (names, handles, bot usernames). Local only, never committed.\n' > "$deny"
  echo "  Add private terms that must never be committed to: $deny"
fi
