#!/usr/bin/env bash
# 버그를 신고할 때 로그를 한 번에 모아 전달하기 쉽게 한다. 읽기만 하고(설치·실행 상태를 바꾸지 않음) 결과
# 묶음 하나만 새로 만든다. 사람(또는 사람을 대신하는 에이전트)이 실행한다 — bluehop 자신은 부르지 않는다.
#   bash scripts/collect-logs.sh                # 기본 위치(/tmp)에 묶음 생성
#   bash scripts/collect-logs.sh --out DIR       # DIR 에 묶음 생성
set -euo pipefail
usage() {
  cat <<'USAGE'
usage: bash scripts/collect-logs.sh [--out DIR]

Bundles the two bluehop logs (~/Library/Logs/bluehop.log and bluehop-events.jsonl, plus
any rotated .1.. siblings of the latter) into one tar.gz for a bug report. Read-only:
touches no installed file, sends nothing, needs no Full Disk Access. The text log is
already body-free by design (AGENTS.md hard rule); the structured log is too at its
default level, but as a second line of defense this script still drops any JSON Lines
object that carries a "text" field (the one opt-in debug-only field that can hold a
message body) and prints how many lines it dropped. It does not drop the bot token
because the token is never written to either log at any level in the first place.

  --out DIR   write the bundle under this directory (default: a new dir under /tmp)
  -h, --help  print this help and exit without doing anything
USAGE
}
# 도움말과 모르는 인자는 아무 일도 하기 전에(임시 폴더를 만들기도 전에) 판정한다.
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "collect-logs.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$OUT_DIR" ]] || OUT_DIR="$(mktemp -d -t bluehop-logs)"
mkdir -p "$OUT_DIR"

TEXT_LOG="$HOME/Library/Logs/bluehop.log"
EVENT_LOG="$HOME/Library/Logs/bluehop-events.jsonl"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

found=0
dropped=0

if [[ -f "$TEXT_LOG" ]]; then
  cp "$TEXT_LOG" "$STAGE/bluehop.log"
  found=1
fi

# 구조화 로그: 지금 파일 + 돌아간 조각(.1, .2, …). "text" 필드(본문 디버그 opt-in)가 있는 줄만 빼고 옮긴다.
for f in "$EVENT_LOG" "$EVENT_LOG".*; do
  [[ -f "$f" ]] || continue
  found=1
  name="$(basename "$f")"
  before="$(wc -l < "$f" | tr -d ' ')"
  grep -v '"text"[[:space:]]*:' "$f" > "$STAGE/$name" || true
  after="$(wc -l < "$STAGE/$name" | tr -d ' ')"
  dropped=$(( dropped + before - after ))
done

if [[ "$found" -eq 0 ]]; then
  echo "로그가 없습니다 (아직 한 번도 실행되지 않았거나 다른 계정으로 설치됨): $TEXT_LOG" >&2
  exit 1
fi

BUNDLE="$OUT_DIR/bluehop-logs-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$BUNDLE" -C "$STAGE" .
echo "$BUNDLE"
if [[ "$dropped" -gt 0 ]]; then
  echo "주의: 본문이 실렸을 수 있는 줄 ${dropped}개를 빼고 묶었습니다 (BLUEHOP_LOG_BODIES 를 켠 적이 있었을 것입니다)." >&2
fi
