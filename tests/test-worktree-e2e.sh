#!/bin/bash
# worktree 병렬 dev-bounce — UX flow별 찐 e2e (실제 git worktree·실제 hook stdin·실제 resolve-task)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WH="$REPO/scripts/worktree-helper.sh"; HOOKS="$REPO/hooks"
PASS=0; FAIL=0
ok(){ echo "✅ $1"; PASS=$((PASS+1)); }; ng(){ echo "❌ $1"; FAIL=$((FAIL+1)); }
gitc(){ git -c user.email=t@t -c user.name=t "$@"; }

TMP=$(mktemp -d); export HOME="$TMP/home"; mkdir -p "$HOME"
PROJ="$TMP/vibe/proj"; mkdir -p "$TMP/vibe"
mkdir -p "$PROJ" && ( cd "$PROJ" && git init -q && gitc -C "$PROJ" commit --allow-empty -qm init )

# ── F5/F6: worktree 위치 ──
OUT=$(bash "$WH" create "$PROJ" taskB); WT=$(echo "$OUT"|sed -n 's/^WT=//p'); BR=$(echo "$OUT"|sed -n 's/^BRANCH=//p'); BASE=$(echo "$OUT"|sed -n 's/^BASE=//p')
case "$WT" in "$PROJ"/*) ng "F5: worktree 레포 안(Metro위험)";; *) ok "F5: worktree 레포 working tree 밖";; esac
case "$WT" in "$HOME/.claude/"*) ng "F6: ~/.claude 밑";; "$HOME/.ai-bouncer/"*) ok "F6: ~/.ai-bouncer 밑";; *) ng "F6: 예상밖 ($WT)";; esac

# ── F1: 병렬 격리 (메인 task A + worktree task B, 세션별 resolve) ──
TA="$PROJ/.ai-bouncer-tasks/2026-01-01/taskA"; mkdir -p "$TA"; echo "sidA" > "$TA/.active"
echo '{"workflow_phase":"development","plan_approved":true,"resolved_agent_mode":"single","current_dev_phase":1,"current_step":1,"dev_phases":{"1":{"name":"a","folder":"p","steps":{"1":"x"}}},"task_dir":".ai-bouncer-tasks/2026-01-01/taskA","active_file":".ai-bouncer-tasks/2026-01-01/taskA/.active"}' > "$TA/state.json"
TB="$WT/.ai-bouncer-tasks/2026-01-01/taskB"; mkdir -p "$TB"; echo "sidB" > "$TB/.active"
echo '{"workflow_phase":"development","plan_approved":true,"task_dir":".ai-bouncer-tasks/2026-01-01/taskB","active_file":".ai-bouncer-tasks/2026-01-01/taskB/.active"}' > "$TB/state.json"
RA=$(cd "$PROJ" && SESSION_ID=sidA bash -c 'source "'"$HOOKS"'/lib/resolve-task.sh"; echo "$TASK_NAME"')
RB=$(cd "$WT" && SESSION_ID=sidB bash -c 'source "'"$HOOKS"'/lib/resolve-task.sh"; echo "$TASK_NAME"')
[ "$RA" = "taskA" ] && ok "F1: 메인 sidA→taskA" || ng "F1: sidA→$RA"
[ "$RB" = "taskB" ] && ok "F1b: worktree sidB→taskB" || ng "F1b: sidB→$RB"
[ "$(cat "$TA/.active" 2>/dev/null)" = "sidA" ] && ok "F1c: task A .active 무손상" || ng "F1c: A 격리 깨짐"

# ── F8: worktree git이 bash-gate 통과 ──
for cmd in "git worktree list" "git rebase main" "git merge --ff-only foo"; do
  J=$(printf '{"session_id":"sidB","tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")
  D=$(echo "$J" | (cd "$PROJ" && bash "$HOOKS/bash-gate.sh" 2>/dev/null) | jq -r '.decision//"allow"' 2>/dev/null)
  [ "${D:-allow}" = "allow" ] && ok "F8: bash-gate 통과 — $cmd" || ng "F8: 차단 — $cmd"
done

# ── F2 + F4a: done FF머지 + 정리 + 문서복귀(.active 제외) ──
echo "feat" > "$WT/feat.txt"; ( cd "$WT" && gitc add feat.txt && gitc commit -qm "feat: B" )
bash "$WH" finalize "$PROJ" "$WT" "$BR" "$BASE" "$TB" false >/dev/null 2>&1
[ -f "$PROJ/feat.txt" ] && ok "F2: worktree 변경 메인 반영" || ng "F2: 머지 안 됨"
gitc -C "$PROJ" log --oneline | grep -qi merge && ng "F2b: 머지커밋(FF아님)" || ok "F2b: FF(머지커밋0)"
[ ! -d "$WT" ] && ok "F2c: worktree 제거" || ng "F2c: 잔존"
[ -f "$PROJ/.ai-bouncer-tasks/2026-01-01/taskB/state.json" ] && ok "F4a: task 문서 복귀" || ng "F4a: 문서 복귀 안 됨"
[ ! -f "$PROJ/.ai-bouncer-tasks/2026-01-01/taskB/.active" ] && ok "F4a-2: .active 제외" || ng "F4a-2: .active 샘"

# ── F3: rebase 충돌 보존 ──
P2="$TMP/vibe/proj2"; mkdir -p "$P2" && ( cd "$P2" && git init -q && gitc -C "$P2" commit --allow-empty -qm i )
echo v1 > "$P2/c.txt"; ( cd "$P2" && gitc add c.txt && gitc commit -qm v1 )
O2=$(bash "$WH" create "$P2" taskC); W2=$(echo "$O2"|sed -n 's/^WT=//p'); B2=$(echo "$O2"|sed -n 's/^BRANCH=//p'); BA2=$(echo "$O2"|sed -n 's/^BASE=//p')
echo wt > "$W2/c.txt"; ( cd "$W2" && gitc add c.txt && gitc commit -qm wt )
echo b2 > "$P2/c.txt"; ( cd "$P2" && gitc add c.txt && gitc commit -qm v2 )
HB=$(gitc -C "$P2" rev-parse HEAD)
bash "$WH" finalize "$P2" "$W2" "$B2" "$BA2" "" false >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "F3: 충돌 finalize 비-0" || ng "F3: 충돌인데 성공처리"
[ -d "$W2" ] && ok "F3b: worktree 보존" || ng "F3b: 날아감"
[ "$(gitc -C "$P2" rev-parse HEAD)" = "$HB" ] && ok "F3c: base 무손상" || ng "F3c: base 망가짐"

rm -rf "$TMP"
echo ""; echo "결과: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
