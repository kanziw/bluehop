#!/usr/bin/env bash
# 로컬 게이트: 빌드 + 테스트 + 금지 패턴. 커밋 전에 반드시 통과해야 한다.
set -euo pipefail
usage() { printf '%s\n' "usage: bash scripts/check.sh" "" "Local gate: forbidden-pattern scan, swift build, swift test. Writes .build/ only." "" "  -h, --help  print this help and exit without doing anything"; }
# 도움말은 아무 일도 하기 전에 판정한다. 이 스크립트는 인자를 받지 않는다(그 밖의 인자는 종료 코드 2).
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
if [[ $# -gt 0 ]]; then echo "check.sh: unknown argument: $1 (see --help)" >&2; exit 2; fi
cd "$(dirname "$0")/.."
fail=0
bad() { echo "✘ $1" >&2; fail=1; }

# 1) 외부 패키지 0개
grep -n '\.package(' Package.swift && bad "Package.swift 에 외부 패키지(.package)가 있다"
[[ -f Package.resolved ]] && bad "Package.resolved 가 있다(외부 의존성 금지)"

# 2) chat.db 는 읽기 전용으로만: 쓰기 모드는 StateStore 에서만
grep -rn 'readWriteCreate' Sources --include=*.swift | grep -v -E 'Sources/BluehopCore/(StateStore|SQLite)\.swift' && bad "StateStore 밖에서 쓰기 모드로 DB 를 연다"
grep -n 'readOnly' Sources/BluehopCore/ChatDB.swift >/dev/null || bad "ChatDB 가 readOnly 로 열지 않는다"

# 3) 리스닝 소켓·웹 서버 금지
grep -rn -E 'NWListener|\bbind\(|\blisten\(|HTTPServer|NSNetService|CFSocketCreate' Sources && bad "리스닝 소켓 API 사용"

# 4) 하드코딩 URL 은 api.telegram.org 만
urls=$(grep -rhoE 'https?://[A-Za-z0-9.-]+' Sources | sort -u | grep -v '^https://api\.telegram\.org$' || true)
[[ -n "$urls" ]] && bad "허용되지 않은 URL: $urls"

# 5) osascript 는 고정 스크립트 + argv 만
grep -rn 'osascript' Sources --include=*.swift | grep -v -E 'Platform\.swift|// ' && bad "Platform.swift 밖에서 osascript 호출"

[[ $fail -eq 0 ]] || exit 1
echo "✔ 금지 패턴 없음"

swift build 2>&1 | tail -1
swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1
swift test >/dev/null 2>&1 || { echo "✘ swift test 실패" >&2; exit 1; }
echo "✔ check 통과"
