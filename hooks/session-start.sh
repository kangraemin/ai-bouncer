#!/usr/bin/env bash
# SessionStart — 컴파일 최신화, 죽은 lock 정리, 진행 중 작업 복원.
# stdout이 그대로 모델 컨텍스트에 들어간다.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../engine/lib/common.sh"

INPUT="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

SESSION="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)"
CWD="$(jq -r '.cwd // empty'            <<<"$INPUT" 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"
bouncer_defer_to_local "$CWD" "${BASH_SOURCE[0]}" && exit 0

YAML="$(bouncer_workflow_yaml "$CWD")"
COMPILED="$(bouncer_compiled_file "$CWD")"
# 설정이 없는 레포 — 훅은 전역이라 모든 세션에서 뜬다. 켤지는 사용자가 정한다.
# 묻는 건 새 세션을 시작할 때뿐이다 (resume·clear·compact 때마다 물으면 같은 질문이 반복된다).
if [ ! -f "$YAML" ]; then
  [ "$(jq -r '.source // empty' <<<"$INPUT" 2>/dev/null)" = startup ] || exit 0
  TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
  case "$TOP" in "$HOME/.ai-bouncer/"*) exit 0 ;; esac     # 병렬 작업 worktree
  bouncer_init_declined "$TOP" && exit 0
  cat <<EOF

[ai-bouncer] 이 레포($TOP)에는 워크플로우 설정이 없어 ai-bouncer가 꺼져 있다.
사용자의 첫 요청을 처리하기 전에 AskUserQuestion으로 한 번 물어라: "이 레포에 ai-bouncer를 켤까요?"
- 켠다 → \`bouncer init\` (.claude/ai-bouncer/workflow.yaml 을 만든다. 커밋 대상이다)
- 안 켠다 → \`bouncer init --decline\` (이 레포에서는 다시 묻지 않는다)
AskUserQuestion 도구가 없는 세션(claude -p, 위임 실행)이면 묻지 말고 이 안내를 무시한다.
EOF
  exit 0
fi

# ── 1. 필요할 때만 재컴파일 ──────────────────────────────────
# yaml + 참조된 프롬프트 파일 전체의 해시를 비교한다. 프롬프트만 고쳐도 반영된다.
need_compile=1
if [ -f "$COMPILED" ]; then
  old="$(jq -r '.source_sha256 // empty' "$COMPILED" 2>/dev/null)"
  new="$(cd "$(dirname "$YAML")" && jq -r '.sources[]?' "$COMPILED" 2>/dev/null \
          | xargs -I{} cat {} 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  [ -n "$old" ] && [ "$old" = "$new" ] && need_compile=0
fi
if [ "$need_compile" = "1" ]; then
  ENGINE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/engine/compile.py"
  if ! err="$(python3 "$ENGINE" "$YAML" "$COMPILED" 2>&1)"; then
    # 실패해도 기존 compiled.json은 원자적 교체 덕에 그대로 살아 있다.
    printf '⚠️ ai-bouncer: workflow.yaml을 컴파일하지 못했다. 이전 설정으로 계속한다.\n%s\n' "$err"
  fi
fi

# ── 2. 오래 방치된 lock 정리 ─────────────────────────────────
# SessionEnd가 못 뜨는 강제 종료(kill -9 등)에 대한 안전망.
# 하트비트(seen_at)가 오래 멈춘 것만. 기준을 넉넉히 잡아 남의 작업을 뺏지 않는다.
STALE_H="$(bouncer_config stale_lock_hours 12 "$CWD")"
TASKS="$(bouncer_tasks_dir "$CWD")"
if [ -d "$TASKS" ]; then
  for active in "$TASKS"/*/.active; do
    [ -e "$active" ] || continue
    bouncer_sweep_tmp "$(dirname "$active")"
    # 소유자를 읽을 수 없는 락은 아무도 해제할 수 없다 — 시간과 무관하게 회수한다.
    if bouncer_lock_broken "$active"; then
      rm -rf "$active"
      printf 'ℹ️ ai-bouncer: 손상된 잠금을 정리했다 — %s\n' "$(basename "$(dirname "$active")")"
      continue
    fi
    age="$(bouncer_lock_age "$active")"
    [ "$age" -gt $(( STALE_H * 3600 )) ] 2>/dev/null || continue
    rm -f "$active"
    printf 'ℹ️ ai-bouncer: %s시간 넘게 멈춘 잠금을 정리했다 — %s\n' \
      "$STALE_H" "$(basename "$(dirname "$active")")"
  done
fi

# ── 3. 시작 전에 알아야 할 것을 주입 ─────────────────────────
# 모델이 `bouncer scan`을 부를 필요가 없도록 여기서 미리 준다.
COMPILED_OK=0
[ -f "$COMPILED" ] && jq -e . "$COMPILED" >/dev/null 2>&1 && COMPILED_OK=1

if [ "$COMPILED_OK" = 1 ]; then
  if [ -n "$SESSION" ] && TASK="$(bouncer_my_task "$CWD" "$SESSION")"; then
    WF="$(bouncer_state "$TASK" '.workflow')"
    printf '\n[ai-bouncer] 이 세션에 진행 중인 작업이 있다: %s\n' "$(bouncer_state "$TASK" '.task_id')"
    printf '  워크플로우 %s / 현재 단계 %s\n  체인: %s\n' \
      "$WF" "$(bouncer_state "$TASK" '.current_stage')" "$(bouncer_chain "$CWD" "$WF" | tr '\n' ' ')"
    printf '  `bouncer status`로 남은 조건을 확인하고 이어서 진행해라.\n'
  else
    OTHERS=""
    for d in $(bouncer_live_locks "$CWD"); do
      OTHERS="$OTHERS  - $(basename "$d") ($(bouncer_state "$d" '.current_stage'))"$'\n'
    done
    printf '\n[ai-bouncer] 개발 작업은 /dev-bounce 로 시작한다. 사용 가능한 모드:\n'
    jq -r '.workflows | to_entries[] | "  \(.key) — \(.value.label)"' "$COMPILED"
    if [ -n "$OTHERS" ]; then
      printf '  ⚠️ 다른 세션이 잡고 있는 작업:\n%s' "$OTHERS"
      printf '  같은 트리에서 동시에 진행하면 충돌한다 — 병렬로 하려면 --parallel 을 쓴다.\n'
    fi
  fi
fi

exit 0
