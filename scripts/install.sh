#!/usr/bin/env bash
# 설치: 서명된 바이너리 배치 + LaunchAgent 등록. 사람(운영자)이 직접 실행한다.
#   bash scripts/install.sh            # 설정·doctor 통과 시 LaunchAgent 까지 켬
#   bash scripts/install.sh --no-load  # 파일만 배치
set -euo pipefail
cd "$(dirname "$0")/.."
LOAD=1; [[ "${1:-}" == "--no-load" ]] && LOAD=0

SUPPORT="$HOME/Library/Application Support/bluehop"
BIN_DIR="$SUPPORT/bin"
BIN="$BIN_DIR/bluehop"
LOG="$HOME/Library/Logs/bluehop.log"
LABEL="dev.kanziw.bluehop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

bash scripts/check.sh
bash scripts/build-release.sh

umask 077
mkdir -p "$BIN_DIR"
chmod 700 "$SUPPORT" "$BIN_DIR"
# 실행 중인 에이전트를 먼저 내린다(바이너리 교체 중 재시작 방지)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp -f dist/bluehop "$BIN"
chmod 700 "$BIN"
codesign --verify --strict "$BIN"

HAS_CONFIG=1
if [[ ! -f "$SUPPORT/config.json" ]]; then
  HAS_CONFIG=0
  echo "[install] 매핑이 아직 없습니다. 전체 디스크 접근을 준 뒤 추가하세요: \"$BIN\" mapping add (docs/AGENT-GUIDE.md 5단계)"
fi

sed -e "s|__BIN__|$BIN|g" -e "s|__LOG__|$LOG|g" packaging/$LABEL.plist.template > "$PLIST"
chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [[ $LOAD -eq 0 ]]; then
  echo "[install] 배치만 했습니다: $BIN"
  exit 0
fi
if [[ $HAS_CONFIG -eq 0 ]]; then
  echo "[install] 설정이 없어 LaunchAgent 를 켜지 않았습니다. 매핑을 추가한 뒤 다시: bash scripts/install.sh" >&2
  exit 1
fi
# 터미널이 아니라 이 바이너리 자신의 권한으로 점검한다(scripts/agent-run.sh).
if ! BLUEHOP_BIN="$BIN" bash scripts/agent-run.sh doctor; then
  echo "[install] doctor 실패 — LaunchAgent 를 켜지 않았습니다. 고친 뒤: launchctl bootstrap gui/$(id -u) \"$PLIST\"" >&2
  exit 1
fi
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "[install] 켰습니다. 로그: $LOG"
