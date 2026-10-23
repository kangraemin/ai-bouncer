#!/usr/bin/env bash
# 케이스 04 — PreToolUse: 엔진 파일 Edit/Write 차단, 그 밖은 통과, 도구 호출 수 세기
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"

[ -z "$(pre Write '{"file_path":".ai-bouncer/x"}')" ] && ok "작업 없으면 아무것도 막지 않는다" || no "작업 없음"
b1 start main g --pick b=x >/dev/null || abort_setup "start"
TD="$(task_dir)"

blocks(){ blocked "$(pre "$1" "$2")"; }
eng(){ blocks "${1%% *}" "${1#* }"; }
pass(){ ! blocks "${1%% *}" "${1#* }"; }
group "엔진 파일 Edit/Write 차단" eng <<X
Write {"file_path":"$T/.ai-bouncer/tasks/x/state.json"}
Edit {"file_path":".ai-bouncer/tasks/x/.active"}
Write {"file_path":".claude/ai-bouncer/workflow.yaml"}
MultiEdit {"file_path":".claude/ai-bouncer/workflow.compiled.json"}
Write {"file_path":".claude/settings.json"}
Write {"file_path":"sub/../.claude/ai-bouncer/prompts/plan.md"}
NotebookEdit {"notebook_path":".ai-bouncer/n.ipynb"}
X
group "일반 파일·남의 경로는 통과" pass <<X
Write {"file_path":"app.js"}
Edit {"file_path":"$T/src/new.ts"}
Write {"file_path":"/tmp/other/.ai-bouncer/x"}
Write {"file_path":"docs/ai-bouncer.md"}
X

ln -s .ai-bouncer/tasks link; ln -s .claude/ai-bouncer/workflow.yaml app-link.yaml
blocks Write '{"file_path":"link/x/state.json"}' && ok "디렉토리 링크로 우회 차단" || no "디렉토리 링크"
blocks Write '{"file_path":"app-link.yaml"}' && ok "파일 링크로 우회 차단" || no "파일 링크"

# 셸 명령은 보지 않는다 (읽기 오탐이 대부분이었다)
[ -z "$(pre Bash '{"command":"cat .ai-bouncer/tasks/*/state.json"}')" ] && ok "Bash 는 막지 않는다" || no "Bash"

# 도구 호출 수 — Stop 이 "그 사이 아무것도 안 했다"를 아는 근거
s0="$(cat "$TD/.tool_seq" 2>/dev/null || echo 0)"; pre Bash '{"command":"ls"}' >/dev/null
[ "$(cat "$TD/.tool_seq")" -gt "$s0" ] && ok "도구 호출마다 tool_seq 증가" || no "tool_seq"
s1="$(cat "$TD/.tool_seq")"; pre Bash '{"command":"bouncer status"}' >/dev/null
[ "$(cat "$TD/.tool_seq")" = "$s1" ] && ok "순수 bouncer 호출은 세지 않는다(면제)" || no "bouncer 면제"
s1="$(cat "$TD/.tool_seq")"; pre Bash '{"command":"bouncer status && rm -rf x"}' >/dev/null
[ "$(cat "$TD/.tool_seq")" -gt "$s1" ] && ok "연산자 붙은 bouncer 는 면제 아님" || no "면제 우회"

# 상태·설정이 깨지면 규칙을 알 수 없다 — 막는다
cp "$TD/state.json" /tmp/g.$$; echo '{' > "$TD/state.json"
blocks Write '{"file_path":"app.js"}' && ok "state 손상 → 모든 편집 차단" || no "state 손상"
cp /tmp/g.$$ "$TD/state.json"; rm -f /tmp/g.$$
blocked "$(pre Write '{"file_path":".ai-bouncer/x"}' S2)" && no "남의 세션에 적용됨" || ok "다른 세션에는 적용 안 함"

b1 cancel >/dev/null
[ -z "$(pre Write '{"file_path":".ai-bouncer/x"}')" ] && ok "cancel 뒤엔 막지 않는다" || no "cancel 뒤"

cleanup; finish
