#!/bin/bash
# completion-gate: Stop hook
# Claude가 각 응답 턴을 마칠 때 실행
# 검증 단계에서 e2e-result.md 기반으로 검증 통과 여부 확인

HOOK_NAME="completion-gate"
source "$(dirname "${BASH_SOURCE[0]}")/lib/block-logger.sh"

# 세션 격리: session_id 추출 (Stop hook도 stdin JSON 수신)
INPUT=$(cat)
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
# 빈 SESSION_ID면 owner 판정 없이 통과 (Stop hook은 차단 시 세션 wedge → exit 0)
[ -z "$SESSION_ID" ] && exit 0

# 승인된 sub-agent는 completion-gate 스킵 (부모 세션이 관리)
APPROVED_FILE="/tmp/.ai-bouncer-approved-agents"
if [ -n "$SESSION_ID" ] && [ -f "$APPROVED_FILE" ]; then
  if grep -q "^${SESSION_ID}|" "$APPROVED_FILE" 2>/dev/null; then
    exit 0
  fi
fi

# resolve_task_dir: 공유 라이브러리 사용
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"

[ "$IS_MY_TASK" != "true" ] && exit 0
[ -f "$STATE_FILE" ] || exit 0

WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)

# dev-incomplete 차단 카운터: verification/done 전환 시 리셋
case "$WORKFLOW_PHASE" in
  verification|done) rm -f "${TASK_DIR}/.cg-stop-count-${SESSION_ID}" 2>/dev/null ;;
esac

# cancelled/planning/pending 상태 → 통과
case "$WORKFLOW_PHASE" in
  cancelled|planning|pending) exit 0 ;;
esac

# done 상태: e2e 검증 완료 여부 확인 (검증 없이 done 처리된 경우 차단)
if [ "$WORKFLOW_PHASE" = "done" ] && [ "$PLAN_APPROVED" = "true" ]; then
  E2E_RESULT="${TASK_DIR}/verifications/e2e-result.md"
  if [ ! -f "$E2E_RESULT" ]; then
    log_block "CG-DONE-NO-VERIFY-FILE" "⛔ 검증 없이 done 처리됨. e2e-result.md 없음."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("⛔ 검증 없이 done 처리됨. [" + $task + "] verifications/e2e-result.md가 없습니다. Phase 4에서 e2e-writer를 실행하세요.")
    }'
    exit 0
  fi
  HAS_PASS=$(grep -A1 "^## 결론" "$E2E_RESULT" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
  if [ "$HAS_PASS" != "1" ]; then
    log_block "CG-DONE-NOT-PASSED" "⛔ 검증 미통과 상태로 done 처리됨."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("⛔ 검증 미통과 상태로 done 처리됨. [" + $task + "] e2e-result.md의 \"## 결론\"이 통과여야 합니다.")
    }'
    exit 0
  fi
  exit 0
fi

# development 상태에서: 모든 phase/step ✅ 체크
if [ "$WORKFLOW_PHASE" = "development" ] && [ "$PLAN_APPROVED" = "true" ]; then
  PHASE_COUNT=$(jq 'if .dev_phases | type == "object" then .dev_phases | keys | length else 0 end' "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$PHASE_COUNT" -gt 0 ]; then
    ALL_DONE=true
    BLOCK_REASON=""

    for i in $(seq 1 "$PHASE_COUNT"); do
      PHASE_FOLDER=$(_get_phase_folder "$STATE_FILE" "$i")
      PHASE_PATH="${TASK_DIR}/${PHASE_FOLDER}"

      if [ ! -d "$PHASE_PATH" ]; then
        ALL_DONE=false
        BLOCK_REASON="Phase ${i} (${PHASE_FOLDER}) 디렉토리가 없습니다"
        break
      fi

      STEP_FILES=$(ls "${PHASE_PATH}"/step-*.md 2>/dev/null)
      if [ -z "$STEP_FILES" ]; then
        ALL_DONE=false
        BLOCK_REASON="Phase ${i} (${PHASE_FOLDER}) step 파일이 없습니다"
        break
      fi

      for step_file in $STEP_FILES; do
        if ! grep -q "✅" "$step_file" 2>/dev/null; then
          ALL_DONE=false
          STEP_NAME=$(basename "$step_file")
          BLOCK_REASON="Phase ${i} / ${STEP_NAME} 미완료 (✅ 없음)"
          break 2
        fi
        # TC 실제결과 컬럼(6번째 필드)에 ✅ 없는 행 탐지 — ⏸️/❌/빈셀/임의텍스트 모두 차단
        INCOMPLETE_TC=$(awk -F'|' '/^\| TC-[0-9]/{gsub(/ /,"",$6); if ($6 !~ /✅/) print NR}' "$step_file" 2>/dev/null | head -1)
        if [ -n "$INCOMPLETE_TC" ]; then
          ALL_DONE=false
          STEP_NAME=$(basename "$step_file")
          BLOCK_REASON="Phase ${i} / ${STEP_NAME} 미완료 (TC 실제결과 컬럼에 ✅ 없는 행 존재)"
          break 2
        fi
      done
    done

    if [ "$ALL_DONE" = "false" ]; then
      log_block "CG-DEV-PHASE-STEP-INCOMPLETE" "⛔ 개발 미완료 — Phase/Step ✅ 누락."

      # 세션+작업별 차단 횟수. 파일 = 2줄(count, 직전 BLOCK_REASON).
      # 같은 지점(BLOCK_REASON 동일)에서 막힐 때만 누적, 블로킹 지점이 바뀌면(=진행됨) 1로 리셋.
      # 최대 10 cap, 통과는 절대 안 시킴.
      CG_COUNT_FILE="${TASK_DIR}/.cg-stop-count-${SESSION_ID}"
      PREV_COUNT=$(sed -n '1p' "$CG_COUNT_FILE" 2>/dev/null)
      PREV_REASON=$(sed -n '2p' "$CG_COUNT_FILE" 2>/dev/null)
      case "$PREV_COUNT" in ''|*[!0-9]*) PREV_COUNT=0 ;; esac
      if [ "$PREV_REASON" = "$BLOCK_REASON" ]; then
        CG_COUNT=$((PREV_COUNT + 1))   # 같은 지점 정체 → 누적
      else
        CG_COUNT=1                     # 블로킹 지점 변경 = 진행됨 → 리셋
      fi
      [ "$CG_COUNT" -gt 10 ] && CG_COUNT=10
      printf '%s\n%s\n' "$CG_COUNT" "$BLOCK_REASON" > "$CG_COUNT_FILE" 2>/dev/null

      case "$CG_COUNT" in
        1)  ESC="다음 미완료 step으로 즉시 진행하라. 사용자에게 진행 여부를 묻지 마라." ;;
        2)  ESC="[2회 차단] 방금 또 멈추려 했다. \"계속 갈까/끊을까\" 류 질문은 금지다. 묻지 말고 지금 다음 step을 시작하라." ;;
        3)  ESC="[3회 차단] 진행 여부를 묻는 것 자체가 dev-bounce 규칙(SKILL 3-1) 위반이다. 요약·체크인 멈추고 다음 step 코드를 작성하라." ;;
        4)  ESC="[4회 차단] context limit에 실제로 도달하지 않았다. \"컨텍스트가 찼다/한 세션에 무리다\"는 판단은 금지. 즉시 다음 step을 구현하라." ;;
        5)  ESC="[5회 차단] 중단·컨펌요청·scope 자기제한은 hook 차단과 동급 위반이다. 변명 없이 다음 미완료 step 코드를 작성하라." ;;
        6)  ESC="[6회 차단] 멈춤 시도가 반복되고 있다. 남은 step을 보고만 하지 말고 지금 Edit/Write로 구현을 시작하라." ;;
        7)  ESC="[7회 차단] 어떤 질문·체크인·진행상황 요약도 출력하지 마라. 다음 도구 호출은 반드시 다음 step의 Edit/Write/Bash여야 한다." ;;
        8)  ESC="[8회 차단] 또 멈췄다. 사용자는 끝까지 진행하라고 이미 지시했다. 더 묻지 말고 코드만 작성하라." ;;
        9)  ESC="[9회 차단] 경고 한계 직전. 다음 step을 구현할 수 있으면 즉시 구현하라. 정말 막혔다면 다음 차단에서 사용자 개입을 요청하게 된다." ;;
        *)  ESC="[10회 차단 — 한계 도달] 10번 연속 막혔다 = 단순 진행확인 질문이 아니라 실제로 막혔을 가능성이 크다. 단, 통과는 시켜주지 않는다. 다음 step을 구현할 수 있으면 지금 즉시 구현하라. 기술적·기획적으로 정말 해결 불가한 블로커라면 멈춰 있지 말고 AskUserQuestion 도구로 (a) 막힌 지점 (b) 사용자가 골라야 할 구체적 선택지를 제시해 액션을 받아라. '계속할까?'식 단순 진행확인 질문은 여전히 금지 — 반드시 구체적 선택지를 제시할 것." ;;
      esac

      jq -n --arg reason "$BLOCK_REASON" --arg task "$TASK_NAME" --arg esc "$ESC" '{
        decision: "block",
        reason: ("개발이 완료되지 않았습니다. [" + $task + "] " + $reason + ". 현재 Phase/Step을 완료 후 ✅ 표시하세요. " + $esc)
      }'
      exit 0
    fi

    # 모든 step ✅ 완료 → verification 전환 강제 (current_dev_phase 값 무관)
    rm -f "${TASK_DIR}/.cg-stop-count-${SESSION_ID}" 2>/dev/null
    log_block "CG-DEV-ALL-DONE-AWAIT-VERIFY" "⛔ 모든 Phase/Step 완료 — verification 전환 필요."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("모든 Phase/Step이 완료되었습니다. [" + $task + "] state.json의 workflow_phase를 \"verification\"으로 전환하고 e2e-writer 에이전트를 실행하세요.")
    }'
    exit 0
  fi
  exit 0
fi

# 검증 단계에서만 체크
if [ "$PLAN_APPROVED" = "true" ] && [ "$WORKFLOW_PHASE" = "verification" ]; then
  E2E_RESULT="${TASK_DIR}/verifications/e2e-result.md"

  if [ ! -f "$E2E_RESULT" ]; then
    log_block "CG-VERIFY-NO-FILE" "⛔ verification 단계 — e2e-result.md 없음."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] verifications/e2e-result.md 없음. e2e-writer 에이전트를 통해 e2e 테스트를 실행하세요.")
    }'
    exit 0
  fi

  # ## 결론 섹션 + 통과 확인
  HAS_PASS=$(grep -A1 "^## 결론" "$E2E_RESULT" 2>/dev/null | grep -q "^통과" && echo 1 || echo 0)
  if [ "$HAS_PASS" != "1" ]; then
    log_block "CG-VERIFY-NOT-PASSED" "⛔ verification 단계 — e2e-result.md 미통과."
    jq -n --arg task "$TASK_NAME" '{
      decision: "block",
      reason: ("검증이 완료되지 않았습니다. 작업 [" + $task + "] e2e-result.md가 통과해야 합니다. e2e-writer 에이전트를 통해 재실행하세요.")
    }'
    exit 0
  fi
fi

exit 0
