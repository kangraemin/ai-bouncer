#!/usr/bin/env bash
# ai-bouncer 부트스트랩 — 저장소를 받아 요청한 동작을 실행한다.
#
#   curl -fsSL <이 파일 URL> | bash              현재 프로젝트에 설치
#   curl -fsSL <이 파일 URL> | bash -s update    최신으로 갱신 (설치와 동일, 설정은 보존)
#   curl -fsSL <이 파일 URL> | bash -s uninstall  제거
#   curl -fsSL <이 파일 URL> | bash -s migrate    구버전(전역 설치)에서 이관

set -euo pipefail
REPO="${BOUNCER_REPO:-kangraemin/ai-bouncer}"
BRANCH="${BOUNCER_BRANCH:-main}"
ACTION="${1:-install}"
[ $# -gt 0 ] && shift

for c in git jq python3; do
  command -v "$c" >/dev/null 2>&1 || { printf 'ai-bouncer: %s 가 필요합니다.\n' "$c" >&2; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 -b "$BRANCH" "https://github.com/$REPO.git" "$TMP/src" -q 2>/dev/null \
  || { printf 'ai-bouncer: 저장소를 받지 못했습니다 (%s@%s).\n' "$REPO" "$BRANCH" >&2; exit 1; }

case "$ACTION" in
  install|update) exec bash "$TMP/src/install.sh" --ci "$@" ;;
  uninstall)      exec bash "$TMP/src/uninstall.sh" "$@" ;;
  migrate)        exec bash "$TMP/src/migrate.sh" "$@" ;;
  *) printf 'ai-bouncer: 알 수 없는 동작: %s (install|update|uninstall|migrate)\n' "$ACTION" >&2; exit 1 ;;
esac
