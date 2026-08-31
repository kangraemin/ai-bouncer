#!/usr/bin/env bash
# 구버전 → 신규 자동 이관 shim.
#
# 이 파일의 경로는 구버전이 자기 자신을 갱신할 때 받아가는 경로다.
# 구 업데이터는 이 파일을 받아 자신을 덮어쓴 뒤 exec으로 즉시 재실행한다.
# 그래서 여기에 이관 로직을 두면 구버전 사용자는 세션을 시작하기만 해도 넘어온다.
#
# 이 파일을 지우거나 이름을 바꾸면 구버전 사용자의 자동 이관 경로가 끊긴다.
# 신규 설치에는 쓰이지 않는다 (신규는 scripts/update-check.sh 를 쓴다).

set -uo pipefail
REPO="${BOUNCER_REPO:-kangraemin/ai-bouncer}"
G="$HOME/.claude"

printf '\n────────────────────────────────────────────────\n'
printf 'ai-bouncer 구조가 바뀌었습니다. 자동으로 이관합니다.\n'
printf '  전역 설치 → 프로젝트별 설치\n'
printf '  hook 7개 → 5개, 워크플로우를 workflow.yaml로 분리\n'
printf '────────────────────────────────────────────────\n'

for c in git jq python3; do
  command -v "$c" >/dev/null 2>&1 || {
    printf 'ai-bouncer: %s 가 필요합니다. 설치 후 다시 시도하세요.\n' "$c" >&2; exit 0; }
done

# BOUNCER_SRC 가 있으면 그 저장소를 쓴다 (테스트용 이음새).
if [ -n "${BOUNCER_SRC:-}" ] && [ -f "$BOUNCER_SRC/migrate.sh" ]; then
  MIG="$BOUNCER_SRC/migrate.sh"
else
  CLONE="$(mktemp -d)" || exit 0
  trap 'rm -rf "$CLONE"' EXIT
  if ! git clone --depth 1 "https://github.com/$REPO.git" "$CLONE/ai-bouncer" -q 2>/dev/null; then
    printf 'ai-bouncer: 저장소를 받지 못했습니다. 네트워크 확인 후 다시 시도하세요.\n' >&2
    exit 0
  fi
  MIG="$CLONE/ai-bouncer/migrate.sh"
fi
[ -f "$MIG" ] || { printf 'ai-bouncer: migrate.sh 를 찾지 못했습니다.\n' >&2; exit 0; }

# 전역 정리가 먼저다. 이게 끝나야 구 hook 7개가 등록 해제되어
# 이 스크립트가 다시 실행되는 일이 없다. (중간에 끊겨도 이 부분은 남는다.)
bash "$MIG" --apply --install 2>&1

printf '\n이관이 끝났습니다.\n'
printf '  각 프로젝트의 .gitignore / CLAUDE.md / .claude/ 가 변경되었습니다 — 커밋 여부는 직접 판단하세요.\n'
printf '  중간에 끊겼다면 다시 실행해도 안전합니다: bash %s/migrate.sh --apply --install\n' "<clone된 저장소>"
printf '  설정은 이제 각 프로젝트의 .claude/ai-bouncer/workflow.yaml 하나입니다.\n\n'
exit 0
