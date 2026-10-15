#!/usr/bin/env bash
# 설치: 서명된 바이너리 배치 + LaunchAgent 등록. 사람(운영자)이 직접 실행한다.
#   bash scripts/install.sh            # 설정·doctor 통과 시 LaunchAgent 까지 켬
#   bash scripts/install.sh --no-load  # 파일만 배치
set -euo pipefail
usage() {
  cat <<'USAGE'
usage: bash scripts/install.sh [--no-load]

Builds, signs and installs bluehop for the current user. Run by a person, not an agent.
Side effects: runs scripts/check.sh and scripts/build-release.sh, stops a running
dev.kanziw.bluehop LaunchAgent (launchctl bootout) BEFORE replacing the binary at
~/Library/Application Support/bluehop/bin/bluehop, and writes
~/Library/LaunchAgents/dev.kanziw.bluehop.plist. Without --no-load it then runs doctor and,
if it passes, starts the LaunchAgent: from then on messages are really relayed.

  --no-load   place the files only; leaves the relay stopped
  -h, --help  print this help and exit without doing anything
USAGE
}
# 도움말은 다른 인자보다 먼저, 아무 일도 하기 전에 판정한다. 모르는 인자는 종료 코드 2.
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
LOAD=1
for a in "$@"; do
  case "$a" in
    --no-load) LOAD=0 ;;
    *) echo "install.sh: unknown argument: $a (see --help)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/.."

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
