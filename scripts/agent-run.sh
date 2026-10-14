#!/usr/bin/env bash
# 설치된 bluehop 을 launchd 를 통해 한 번 실행한다.
# 터미널에서 직접 실행하면 macOS 는 권한(전체 디스크 접근·자동 제어)을 "터미널"의 것으로 판단한다.
# 이 스크립트로 실행하면 bluehop 자신의 권한으로 돈다 → 터미널에 전체 디스크 접근을 줄 필요가 없다.
#   bash scripts/agent-run.sh list-chats
#   bash scripts/agent-run.sh doctor --messages --telegram
set -euo pipefail
BIN="${BLUEHOP_BIN:-$HOME/Library/Application Support/bluehop/bin/bluehop}"
[[ -x "$BIN" ]] || { echo "설치된 바이너리가 없습니다: $BIN (먼저 scripts/install.sh)" >&2; exit 1; }
LABEL="dev.kanziw.bluehop.oneshot"
DOMAIN="gui/$(id -u)"
WORK="$(mktemp -d)"
trap 'launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -rf "$WORK"' EXIT
OUT="$WORK/out.log"
PLIST="$WORK/$LABEL.plist"

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo "<key>Label</key><string>$LABEL</string>"
  echo '<key>ProgramArguments</key><array>'
  for a in "$BIN" "$@"; do
    a="${a//&/&amp;}"; a="${a//</&lt;}"; a="${a//>/&gt;}"
    echo "<string>$a</string>"
  done
  echo '</array>'
  echo '<key>RunAtLoad</key><true/><key>KeepAlive</key><false/>'
  echo "<key>StandardOutPath</key><string>$OUT</string><key>StandardErrorPath</key><string>$OUT</string>"
  echo '</dict></plist>'
} > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
for _ in $(seq 1 120); do
  info="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)"
  if grep -q 'state = not running' <<<"$info" && grep -q 'last exit code' <<<"$info"; then break; fi
  sleep 0.5
done
cat "$OUT" 2>/dev/null || true
code="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk -F'= ' '/last exit code/ {print $2; exit}')"
[[ "${code:-1}" == "0" ]]
