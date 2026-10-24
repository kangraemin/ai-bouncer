#!/usr/bin/env bash
# update 한 번으로 전역 엔진이 갱신되고, 켠 레포 전부의 옛 로컬 설치본이 정리되는지 e2e
#   - 켜면 목록에 기록된다
#   - 목록에 없던(목록 도입 전) 레포도 홈 아래 탐색으로 찾는다
#   - 설정이 사라진 레포는 목록에서 빠진다
set -u   # pipefail 은 끈다 — `명령 | grep -q` 가 SIGPIPE 로 오판된다
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CLAUDE_CONFIG_DIR XDG_STATE_HOME
H="$(cd "$(mktemp -d)" && pwd -P)"; export HOME="$H" BOUNCER_SCAN_ROOT="$H/work" BOUNCER_REGISTRY_DIR="$H/reg"
trap 'rm -rf "$H"' EXIT
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

mk(){ mkdir -p "$1"; (cd "$1" && git init -q . && git config user.email t@t && git config user.name t \
      && echo x > a && git add a && git commit -qm init); }
mk "$H/work/p1"; mk "$H/work/sub/p2"; mk "$H/work/p3"

(cd "$H/work/p1" && bash "$R/install.sh" --ci >/dev/null 2>&1)
(cd "$H/work/p3" && bash "$R/install.sh" --ci >/dev/null 2>&1)
grep -qx "$H/work/p1" "$BOUNCER_REGISTRY_DIR/installs" && ok "켜면 목록에 기록" || no "목록 기록"

# 목록 도입 전에 깐 옛 로컬 설치본 재현: p2 에 설정 + 레포 안 엔진을 두고 목록에는 없다
mkdir -p "$H/work/sub/p2/.claude/ai-bouncer/engine"
cat > "$H/work/sub/p2/.claude/ai-bouncer/workflow.yaml" <<'Y'
version: 1
stages:
  verify:
    steps: [{label: 테스트, run: "make test"}]
Y
printf 'old\n' > "$H/work/sub/p2/.claude/ai-bouncer/engine/bouncer.sh"

# p1 은 사용자가 고친 설정
printf 'workflows:\n  mine: {stages: [implement, verify]}\n' > "$H/work/p1/.claude/ai-bouncer/workflow.yaml"

# p3 는 설정을 지운 레포
rm -rf "$H/work/p3/.claude/ai-bouncer"

echo '{"commit":"old"}' > "$H/.claude/ai-bouncer/installed.json"
out="$(cd "$H/work/p1" && bash "$R/update-all.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "update-all 종료코드 0" || no "종료코드" "$rc / $(printf '%s' "$out" | tail -3)"
[ "$(jq -r .commit "$H/.claude/ai-bouncer/installed.json")" != old ] && ok "전역 엔진 갱신" || no "전역 엔진 갱신 안 됨"
[ -e "$H/work/sub/p2/.claude/ai-bouncer/engine" ] && no "p2 옛 로컬 엔진 남음" || ok "옛 로컬 설치본 정리"
[ -f "$H/work/sub/p2/.claude/ai-bouncer/workflow.compiled.json" ] && ok "p2 설정 컴파일" || no "p2 컴파일"
grep -qx "$H/work/sub/p2" "$BOUNCER_REGISTRY_DIR/installs" && ok "탐색으로 찾은 레포를 목록에 추가" || no "탐색 결과 목록 반영"
grep -qx "$H/work/p3" "$BOUNCER_REGISTRY_DIR/installs" && no "설정 없는 레포가 목록에 남음" || ok "설정 없는 레포는 목록에서 뺌"
printf '%s' "$out" | grep -q '켠 레포 2곳' && ok "대상 수 보고" || no "대상 수" "$(printf '%s' "$out" | head -3)"

[ "$(jq -c '.stages.verify.items[]|select(.id=="make-test")|.run' "$H/work/sub/p2/.claude/ai-bouncer/workflow.compiled.json")" = '["bouncer passed make-test"]' ] \
  && ok "옛 형식 설정을 변환 (run 보존)" || no "옛 형식 변환" "$(cat "$H/work/sub/p2/.claude/ai-bouncer/workflow.yaml")"
[ "$(jq -r '.workflows|keys|join(",")' "$H/work/p1/.claude/ai-bouncer/workflow.compiled.json")" = mine ] \
  && ok "사용자 설정 보존" || no "사용자 설정"
n="$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' "$H/.claude/settings.json")"
[ "$n" = 4 ] && ok "전역 hook 4개" || no "hook 수" "$n"
cp "$H/work/sub/p2/.claude/ai-bouncer/workflow.yaml" "$H/p2.once"
(cd "$H/work/p1" && bash "$R/update-all.sh" >/dev/null 2>&1) && ok "두 번째 update-all 도 성공" || no "재실행"
cmp -s "$H/work/sub/p2/.claude/ai-bouncer/workflow.yaml" "$H/p2.once" && ok "두 번 돌려도 설정 그대로(멱등)" || no "멱등"
[ "$(jq '[.hooks // {} | to_entries[] | .value[] | .hooks[] | select(.command | contains("ai-bouncer"))] | length' "$H/.claude/settings.json")" = 4 ] \
  && ok "재실행해도 hook 중복 없음" || no "hook 중복"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
