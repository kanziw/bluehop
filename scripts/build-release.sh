#!/usr/bin/env bash
# release 빌드 → Info.plist 내장 → 서명 → dist/bluehop
# 서명 identity: BLUEHOP_CODESIGN_IDENTITY > 키체인의 Developer ID Application/Apple Development > ad-hoc
# ad-hoc 이면 빌드마다 identity 가 바뀌어 전체 디스크 접근·자동 제어 승인을 재설치마다 다시 해야 한다.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

swift build -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/packaging/Info.plist"
BIN="$(swift build -c release --show-bin-path)/bluehop"
mkdir -p dist
cp -f "$BIN" dist/bluehop

IDENTITY="${BLUEHOP_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"(Developer ID Application|Apple Development)/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "[build] 서명 인증서 없음 — ad-hoc 서명(재설치마다 권한 재승인 필요)" >&2
else
  echo "[build] 서명: $IDENTITY"
fi
codesign --force --sign "$IDENTITY" --identifier dev.kanziw.bluehop \
  --options runtime --entitlements packaging/bluehop.entitlements --timestamp=none dist/bluehop
codesign --verify --strict dist/bluehop
codesign -dv dist/bluehop 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)=' | head -3
shasum -a 256 dist/bluehop
