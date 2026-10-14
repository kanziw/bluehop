#!/usr/bin/env bash
# Checks only the lines being added in the staged diff (used by .githooks/pre-commit):
#   1) whitespace errors and conflict markers (git diff --check)
#   2) tab indentation in Swift, shell, YAML and Python files
#   3) secret and personal-data shapes: bot tokens, phone numbers, chat guids with a real-looking
#      handle, Telegram numeric ids next to id keys, personal e-mail domains
#   4) terms listed one per line in .git/info/pii-denylist (local, never committed)
# Documented placeholders (+15555550123, +8210XXXXXXXX, +821012345678, +821011112222,
# +821033334444, 123456789) are allowed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
bad() { echo "✘ pre-commit: $1" >&2; fail=1; }

git diff --cached --check >&2 || bad "whitespace error or conflict marker (see above)"

added="$(git diff --cached -U0 --no-color --diff-filter=ACMR | awk '
  /^\+\+\+ /{ f = substr($0, 7); next }
  /^\+/ { print f ":" substr($0, 2) }')"
[[ -z "$added" ]] && exit 0

tabs="$(grep -E $'^[^:]+\\.(swift|sh|ya?ml|py):\t' <<<"$added" || true)"
[[ -n "$tabs" ]] && bad "tab indentation (this repo uses spaces):"$'\n'"$(cut -c1-120 <<<"$tabs")"

placeholders='(\+15555550123|\+8210X+|\+821012345678|\+821011112222|\+821033334444|123456789)'
scan() {  # $1 label, $2 extended regex
  local hits
  hits="$(grep -E -- "$2" <<<"$added" | grep -v -E -- "$placeholders" || true)"
  [[ -n "$hits" ]] && bad "$1 (value hidden; file names only): $(cut -d: -f1 <<<"$hits" | sort -u | tr '\n' ' ')"
  return 0
}
scan "Telegram bot token shape" '[0-9]{8,10}:[A-Za-z0-9_-]{35}'
scan "phone number" '(\+82[ -]?1[016789][0-9 -]{7,10}|(^|[^0-9])010[ -]?[0-9]{4}[ -]?[0-9]{4}([^0-9]|$)|\+1[2-9][0-9]{9}([^0-9]|$))'
scan "chat guid with a real-looking handle" '(any|iMessage|SMS);[-+];(\+?[0-9]{7,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,})'
scan "Telegram numeric id next to an id key" '(chatId|allowedUserId|chat_id|user_id|chatID|userID)["'"'"' ]*[:=][ ]*-?[0-9]{6,}'
scan "personal e-mail address" '[A-Za-z0-9._%+-]+@(gmail|googlemail|naver|daum|hanmail|kakao|icloud|me|mac|hotmail|outlook|yahoo|proton|protonmail)\.(com|net)'

deny="$(git rev-parse --git-path info/pii-denylist)"
if [[ -f "$deny" ]]; then
  while IFS= read -r term; do
    [[ -z "$term" || "$term" == \#* ]] && continue
    hits="$(grep -F -i -- "$term" <<<"$added" || true)"
    [[ -n "$hits" ]] && bad "term from .git/info/pii-denylist found in: $(cut -d: -f1 <<<"$hits" | sort -u | tr '\n' ' ')"
  done < "$deny"
fi

if [[ $fail -ne 0 ]]; then
  echo "  Fix the staged files (or use a documented placeholder). Do not bypass with --no-verify." >&2
  exit 1
fi
echo "✔ pre-commit: staged changes clean" >&2
