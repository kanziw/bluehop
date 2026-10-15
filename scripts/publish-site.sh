#!/usr/bin/env bash
# docs/site/ + llms.txt 를 gh-pages 브랜치에 한 커밋으로 올린다(https://kanziw.dev/bluehop/).
set -euo pipefail
usage() {
  cat <<'USAGE'
usage: bash scripts/publish-site.sh [--push]

Copies docs/site/* and llms.txt into a temporary git worktree of origin/gh-pages and commits
"docs(site): publish the bluehop site from docs/site at vX.Y.Z" on the local gh-pages branch.
Nothing leaves this machine without --push. The temporary worktree is removed at the end.

  --push      also push gh-pages to origin (GitHub Pages then rebuilds the site)
  -h, --help  print this help and exit without doing anything
USAGE
}
# 도움말은 아무 일도 하기 전에 판정한다. 모르는 인자는 종료 코드 2.
for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
PUSH=0
for a in "$@"; do
  case "$a" in
    --push) PUSH=1 ;;
    *) echo "publish-site.sh: unknown argument: $a (see --help)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/.."
REPO="$PWD"
version="$(awk -F'"' '/^let version/ {print $2; exit}' Sources/BluehopCLI/main.swift)"
[[ -n "$version" ]] || { echo "publish-site.sh: version not found in main.swift" >&2; exit 1; }

git fetch -q origin gh-pages
WT="$(mktemp -d)"
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
git worktree add -q -B gh-pages "$WT" origin/gh-pages
find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R docs/site/. "$WT/"
cp llms.txt "$WT/llms.txt"
touch "$WT/.nojekyll"
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  echo "[site] no change against origin/gh-pages"
else
  git -C "$WT" commit -q -m "docs(site): publish the bluehop site from docs/site at v$version"
  echo "[site] committed $(git -C "$WT" rev-parse --short HEAD) on gh-pages"
fi
if [[ $PUSH -eq 1 ]]; then
  # 저장소 루트에서 밀어야 pre-push 훅(scripts/check.sh)이 돈다.
  git -C "$REPO" push origin gh-pages
fi
