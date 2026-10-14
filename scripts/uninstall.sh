#!/usr/bin/env bash
# LaunchAgent 를 내리고 바이너리를 지운다. 설정·상태(매핑)는 남긴다(--purge 면 설정·상태·모든 매핑의 Keychain 봇 토큰까지 삭제).
set -euo pipefail
LABEL="dev.kanziw.bluehop"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/bluehop"
rm -rf "${SUPPORT:?}/bin" "${SUPPORT:?}/tmp" "${SUPPORT:?}/outbox"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "${SUPPORT:?}"
  # 매핑마다 봇 토큰 항목이 하나씩 있다(계정 bot-token:<id>, 옮겨 온 default 는 telegram-bot-token). 서비스의 항목을 모두 지운다.
  for _ in $(seq 1 100); do
    security delete-generic-password -s "$LABEL" >/dev/null 2>&1 || break
  done
fi
echo "제거함. 시스템 설정의 전체 디스크 접근·자동화 목록에서 bluehop 항목도 지우세요."
