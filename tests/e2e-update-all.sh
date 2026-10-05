#!/usr/bin/env bash
# update 한 번으로 이 컴퓨터의 설치본 전부가 갱신되는지 e2e
#   - 설치하면 설치 목록에 기록된다
#   - 목록에 없던(목록 도입 전) 설치본도 홈 아래 탐색으로 찾는다
#   - 사라진 설치본은 목록에서 빠진다
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
grep -qx "$H/work/p1" "$BOUNCER_REGISTRY_DIR/installs" && ok "설치하면 목록에 기록" || no "목록 기록"

# 목록 도입 전 설치본 재현: p2 를 설치한 뒤 목록에서 지운다
(cd "$H/work/sub/p2" && bash "$R/install.sh" --ci >/dev/null 2>&1)
grep -vx "$H/work/sub/p2" "$BOUNCER_REGISTRY_DIR/installs" > "$H/t" && mv "$H/t" "$BOUNCER_REGISTRY_DIR/installs"

# p3 는 사라진 설치본
rm -rf "$H/work/p3/.claude/ai-bouncer"

for p in p1 sub/p2; do echo '{"commit":"old"}' > "$H/work/$p/.claude/ai-bouncer/installed.json"; done
out="$(cd "$H/work/p1" && bash "$R/update-all.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "update-all 종료코드 0" || no "종료코드" "$rc / $(printf '%s' "$out" | tail -3)"
for p in p1 sub/p2; do
  c="$(jq -r .commit "$H/work/$p/.claude/ai-bouncer/installed.json")"
  [ "$c" != old ] && ok "$p 갱신됨" || no "$p 갱신 안 됨"
done
grep -qx "$H/work/sub/p2" "$BOUNCER_REGISTRY_DIR/installs" && ok "탐색으로 찾은 설치본을 목록에 추가" || no "탐색 결과 목록 반영"
grep -qx "$H/work/p3" "$BOUNCER_REGISTRY_DIR/installs" && no "사라진 설치본이 목록에 남음" || ok "사라진 설치본은 목록에서 뺌"
printf '%s' "$out" | grep -q '설치본 2곳' && ok "대상 수 보고" || no "대상 수" "$(printf '%s' "$out" | head -2)"

printf '\n결과: %d 통과 / %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
