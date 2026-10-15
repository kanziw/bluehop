#!/usr/bin/env bash
# One-time setup for a clone: use the repo's versioned git hooks.
#   pre-commit  -> scripts/check-staged.sh (whitespace, tabs, secret/personal-data shapes)
#   commit-msg  -> Conventional Commits subject check
#   pre-push    -> scripts/check.sh (forbidden patterns + swift build + swift test)
set -euo pipefail
usage() { printf '%s\n' "usage: bash scripts/setup-dev.sh" "" "Sets core.hooksPath=.githooks in this clone and creates the local .git/info/pii-denylist." "" "  -h, --help  print this help and exit without doing anything"; }
# 도움말은 아무 일도 하기 전에 판정한다. 이 스크립트는 인자를 받지 않는다(그 밖의 인자는 종료 코드 2).
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
if [[ $# -gt 0 ]]; then echo "setup-dev.sh: unknown argument: $1 (see --help)" >&2; exit 2; fi
cd "$(dirname "$0")/.."
chmod +x .githooks/* scripts/check-staged.sh
git config core.hooksPath .githooks
echo "✔ git hooks enabled (core.hooksPath=.githooks)"
deny="$(git rev-parse --git-path info/pii-denylist)"
if [[ ! -f "$deny" ]]; then
  printf '# One term per line (names, handles, bot usernames). Local only, never committed.\n' > "$deny"
  echo "  Add private terms that must never be committed to: $deny"
fi
