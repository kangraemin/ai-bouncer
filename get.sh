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

# exec을 쓰면 trap이 실행되지 않아 clone 디렉토리가 남는다. 실행 후 직접 정리한다.
rc=0
case "$ACTION" in
  # 받아온 브랜치를 설치에도 그대로 넘긴다. 안 넘기면 다음 자동 업데이트에
  # main으로 조용히 되돌아간다.
  install|update) bash "$TMP/src/install.sh" --ci --branch "$BRANCH" "$@" || rc=$? ;;
  uninstall)      bash "$TMP/src/uninstall.sh" "$@" || rc=$? ;;
  migrate)        bash "$TMP/src/migrate.sh" "$@" || rc=$? ;;
  *) printf 'ai-bouncer: 알 수 없는 동작: %s (install|update|uninstall|migrate)\n' "$ACTION" >&2; rc=1 ;;
esac
exit "$rc"
