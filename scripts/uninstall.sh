#!/usr/bin/env bash
# LaunchAgent 를 내리고 바이너리를 지운다. 설정·상태(매핑)는 남긴다(--purge 면 모두 삭제).
set -euo pipefail
LABEL="dev.kanziw.imsg-relay"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/imsg-relay"
rm -rf "$SUPPORT/bin" "$SUPPORT/tmp" "$SUPPORT/outbox"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SUPPORT"
  security delete-generic-password -s "$LABEL" -a telegram-bot-token >/dev/null 2>&1 || true
fi
echo "제거함. 시스템 설정의 전체 디스크 접근·자동화 목록에서 imsg-relay 항목도 지우세요."
