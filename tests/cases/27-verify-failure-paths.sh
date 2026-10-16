#!/usr/bin/env bash
# 케이스 27 — verify 에서 갇히지 않는다.
#
# 2026-10-17: 읽기 전용 verify 에서 optional 스크린샷이 .venv 가 없어 exit 127 로 실패.
# 미실행으로 취급돼 on_fail 반송도 skip 제안도 안 나왔고, venv 를 만들 수도,
# library 에 기록할 수도, `cd .claude/ai-bouncer && grep` 으로 엔진을 읽을 수도 없었다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FIXTURE_DIR="$(mktemp -d)"
cat > "$FIXTURE_DIR/_wf.yaml" <<'Y'
version: 1
workflows:
  plan: {label: 테스트용, stages: [implement, verify, done]}
stages:
  implement:
    steps: [{label: 구현, inject: "구현."}]
  verify:
    on_fail: implement
    steps:
      - {label: 선택검사, run: "exit 3", blocking: true, optional: true}
      - {label: 필수검사, run: "test -f ok.txt", blocking: true}
      - {label: 보고, blocking: done, inject: "보고해라."}
    forbid: {edit_files: true, reason: 읽기 전용}
  done:
    steps: [{label: 완료, inject: "끝."}]
Y
setup "$FIXTURE_DIR/_wf.yaml" || exit 1
trap 'cleanup; rm -rf "$FIXTURE_DIR"' EXIT
export CLAUDE_CODE_SESSION_ID=S1
isblock(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

bouncer start plan vf >/dev/null
stop >/dev/null
[ "$(stage)" = verify ] && ok "verify 로 간다" || no "전이" "$(stage)"

# ── 읽기 전용 게이트 ──
LIB="$(mktemp -d)"; git -C "$LIB" init -q
TMPX="$(mktemp -d)"
r=$(pre Bash "{\"command\":\"printf x > $TMPX/a\"}"); [ -n "$r" ] && ok "레포 아닌 밖(/tmp)은 계속 막는다" || no "/tmp 통과" ""
r=$(pre Bash "{\"command\":\"printf x > $LIB/note.md\"}"); [ -z "$r" ] && ok "프로젝트 밖(library) 쓰기는 허용" || no "밖 쓰기" "${r:0:100}"
r=$(pre Write "{\"file_path\":\"$LIB/n.md\",\"content\":\"x\"}"); [ -z "$r" ] && ok "프로젝트 밖 Write 허용" || no "밖 Write" "${r:0:100}"
r=$(pre Bash '{"command":"printf x > src.js"}'); [ -n "$r" ] && ok "프로젝트 안 쓰기는 여전히 막는다" || no "안 쓰기 통과" ""
r=$(pre Write "{\"file_path\":\"$T/src.js\",\"content\":\"x\"}"); [ -n "$r" ] && ok "프로젝트 안 Write 는 막는다" || no "안 Write 통과" ""
r=$(pre Bash '{"command":"printf x > ~/.claude/settings.json"}'); [ -n "$r" ] && ok "~/.claude 는 계속 막는다" || no "~/.claude 통과" ""
r=$(pre Bash '{"command":"cd .claude/ai-bouncer && grep -rn x . 2>/dev/null"}'); [ -z "$r" ] && ok "엔진 디렉토리로 cd 해서 읽기는 허용" || no "cd 읽기" "${r:0:100}"
r=$(pre Bash '{"command":"echo $(git rev-parse HEAD)"}'); [ -z "$r" ] && ok "읽기 전용 \$() 허용" || no "\$()" "${r:0:100}"
r=$(pre Bash '{"command":"echo $(rm -rf src)"}'); [ -n "$r" ] && ok "\$() 안의 쓰기는 막는다" || no "\$() 안 rm 통과" ""
r=$(pre Bash '{"command":"sed $(echo -i) s/a/b/ a.js"}'); [ -n "$r" ] && ok "치환이 플래그가 되는 명령은 막는다" || no "sed 치환 통과" ""
rm -rf "$LIB" "$TMPX"

# ── run 실패는 done 대기와 상관없이 on_fail 로 반송 ──
# (optional 은 "시작할 때 끌 수 있다"는 뜻이다. 켜져 있으면 게이트다 — 케이스 4)
bouncer run 'verify/선택검사' >/dev/null 2>&1
r=$(stop)
printf "%s" "$r" | jq -r .reason | grep -q "실패 (1회)" && ok "실패한 run 은 미실행이 아니라 실패로 알린다" || no "실패 표기" "${r:0:160}"
[ "$(stage)" = implement ] && ok "보고 done 이 남아 있어도 on_fail 로 반송" || no "반송" "$(stage)"
[ "$(state '.attempts["verify/선택검사"] // 0')" = 0 ] && ok "반송하면 run 실패 횟수도 지운다" || no "attempts 잔존" "$(state .attempts)"
finish
