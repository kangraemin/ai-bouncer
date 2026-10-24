#!/usr/bin/env bash
# 케이스 08 — 세션 폴더와 작업 레포가 다를 때 (설정 없는 폴더에서 열고 `cd 레포 && bouncer start`)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup "$R/tests/fixtures/flow.yaml" "$R/tests/fixtures/prompts" || abort_setup "setup"
O_DIR="$(mktemp -d)"   # 세션이 열린 다른 폴더 (설정 없음)
ostop(){ hook stop "{\"session_id\":\"${1:-S1}\",\"cwd\":\"$O_DIR\",\"stop_hook_active\":false}"; }
opre(){ hook pre-tool "{\"session_id\":\"S1\",\"cwd\":\"$O_DIR\",\"tool_name\":\"$1\",\"tool_input\":$2}"; }

b1 start main t --pick b=x >/dev/null || abort_setup "start"
O="$(ostop)"; blocked "$O" && reason "$O" | grep -q 'test -f a.done' && ok "다른 폴더 세션의 Stop 도 작업을 찾아 run 을 돌린다" || no "다른 폴더 Stop" "$O"
touch a.done; O="$(ostop)"; [ "$(stage)" = b ] && reason "$O" | grep -q '엑스 지시' && ok "다른 폴더에서도 다음 단계로 넘어간다" || no "다른 폴더 전이" "$O"
blocked "$(opre Write "{\"file_path\":\"$T/.ai-bouncer/tasks/x/state.json\"}")" && ok "다른 폴더 세션도 작업 레포의 상태 파일 편집을 막는다" || no "다른 폴더 보호"
[ -z "$(opre Write '{"file_path":".ai-bouncer/tasks/x/state.json"}')" ] && ok "상대 경로는 세션 폴더 기준 (다른 폴더의 같은 이름은 안 막는다)" || no "상대 경로 기준"
[ -z "$(ostop S2)" ] && ok "남의 세션은 표지로 찾지 않는다" || no "남의 세션"
O="$(hook session-start "{\"session_id\":\"S1\",\"cwd\":\"$O_DIR\",\"source\":\"compact\"}")"
printf '%s' "$O" | grep -q '진행 중인 작업이 있다' && printf '%s' "$O" | grep -q '엑스 지시' && ok "다른 폴더 세션 재개 때 작업과 현재 단계 지시 안내" || no "다른 폴더 안내" "$O"
O="$(cd "$O_DIR" && CLAUDE_CODE_SESSION_ID=S1 bash "$R/engine/bouncer.sh" scan)"; printf '%s' "$O" | grep -q $'^STATE\tMINE' && ok "다른 폴더에서 bouncer scan 이 MINE" || no "다른 폴더 scan" "$O"
says "이미 진행 중인 작업" bash -c "cd '$O_DIR' && CLAUDE_CODE_SESSION_ID=S1 bash '$R/engine/bouncer.sh' start main t2 --pick b=x" && ok "한 세션에 작업은 하나 (레포가 달라도)" || no "중복 시작"

hook session-end "{\"session_id\":\"S1\",\"cwd\":\"$O_DIR\"}"
[ ! -f "$(task_dir)/.active" ] && [ ! -f "$HOME/.local/state/ai-bouncer/sessions/S1" ] && ok "세션이 끝나면 다른 레포 작업의 잠금과 표지를 푼다" || no "session-end 표지"
[ -z "$(ostop)" ] && ok "작업이 끝나면 표지는 무시된다" || no "끝난 표지"
rm -rf "$O_DIR"; cleanup; finish
