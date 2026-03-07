#!/bin/bash
# bash-gate: PreToolUse hook (Layer 1)
# Bash 도구로 파일 쓰기 우회 차단 — 쓰기 패턴 휴리스틱 감지

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Bash만 체크
[ "$TOOL" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

# 세션 격리: session_id 추출
export SESSION_ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

# --- ai-bouncer start ---

# 1. Fast exit: 쓰기 패턴 미포함 → exit 0
if ! echo "$CMD" | grep -qE '>[^&]|>>|\btee\b|\bsed\b.*-i|\bcp\b|\bmv\b|\btouch\b|\bdd\b.*of=|\bpython|\bnode\b.*-e|\bruby\b.*-e|\bperl\b.*-e|\brm\b|\brmdir\b|\bunlink\b|\bcurl\b.*(-o|--output)|\bwget\b'; then
  exit 0
fi

# 2. git 명령어 → exit 0 (git commit, push 등)
if echo "$CMD" | grep -qE '^\s*git\b'; then
  exit 0
fi

# 3. 쓰기 패턴 상세 감지
IS_WRITE=false

# 리다이렉트: >, >> (단 >& 제외)
if echo "$CMD" | grep -qE '>[^>&]|>>'; then
  IS_WRITE=true
fi

# tee (파이프로 파일 쓰기)
if echo "$CMD" | grep -qE '\btee\b'; then
  IS_WRITE=true
fi

# sed -i (인플레이스 수정)
if echo "$CMD" | grep -qE '\bsed\b.*-i'; then
  IS_WRITE=true
fi

# cp, mv (파일 복사/이동)
if echo "$CMD" | grep -qE '\bcp\b|\bmv\b'; then
  IS_WRITE=true
fi

# touch (파일 생성)
if echo "$CMD" | grep -qE '\btouch\b'; then
  IS_WRITE=true
fi

# dd of= (블록 디바이스 쓰기)
if echo "$CMD" | grep -qE '\bdd\b.*of='; then
  IS_WRITE=true
fi

# 스크립트 언어로 파일 쓰기
if echo "$CMD" | grep -qE '\bpython[23]?\b.*(-c|<<)|\bnode\b.*-e|\bruby\b.*-e|\bperl\b.*-e'; then
  IS_WRITE=true
fi

# cat/echo + heredoc
if echo "$CMD" | grep -qE '\bcat\b.*>|\becho\b.*>|\bprintf\b.*>'; then
  IS_WRITE=true
fi

# rm, rmdir, unlink (파일/디렉토리 삭제)
if echo "$CMD" | grep -qE '\brm\b|\brmdir\b|\bunlink\b'; then
  IS_WRITE=true
fi

# curl -o/--output (파일 다운로드)
if echo "$CMD" | grep -qE '\bcurl\b.*(-o|--output)'; then
  IS_WRITE=true
fi

# wget (항상 파일 저장)
if echo "$CMD" | grep -qE '\bwget\b'; then
  IS_WRITE=true
fi

[ "$IS_WRITE" = "false" ] && exit 0

# 4. 예외 경로 — gate 관리 파일은 항상 허용
EXCEPTION=false

# ~/.claude/plans/ 경로
if echo "$CMD" | grep -qE '\.claude/plans/'; then
  EXCEPTION=true
fi

# state.json 파일 (.active는 예외 아님 — 비우기로 gate 무력화 방지)
# rm/rmdir/unlink은 state.json도 예외 아님 (삭제 방지)
if echo "$CMD" | grep -qE 'state\.json' && ! echo "$CMD" | grep -qE '\brm\b|\brmdir\b|\bunlink\b'; then
  EXCEPTION=true
fi

# plan.md, step-*.md, phase-*.md, round-*.md
if echo "$CMD" | grep -qE 'plan\.md|step-[0-9]+\.md|phase-[0-9]+.*\.md|round-[0-9]+\.md'; then
  EXCEPTION=true
fi

[ "$EXCEPTION" = "true" ] && exit 0

# 5. Gate 검증 (plan-gate.sh CHECK 2~7 동일)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/resolve-task.sh"

# .active 없거나 비어있으면 → 통과 (gate 비활성)
if [ -z "$TASK_NAME" ]; then
  exit 0
fi

# state.json 없으면 통과
[ -f "$STATE_FILE" ] || exit 0

# state.json 값 읽기
WORKFLOW_PHASE=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
PLAN_APPROVED=$(jq -r '.plan_approved // false' "$STATE_FILE" 2>/dev/null)
MODE=$(jq -r '.mode // "normal"' "$STATE_FILE" 2>/dev/null)
TEAM_NAME=$(jq -r '.team_name // ""' "$STATE_FILE" 2>/dev/null)
CURRENT_DEV_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
CURRENT_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)

# 스냅샷 저장 함수 (Layer 2용)
save_snapshot() {
  { git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort > /tmp/.ai-bouncer-snapshot 2>/dev/null
}

# CHECK 1.5: workflow_phase 화이트리스트
case "$WORKFLOW_PHASE" in
  planning|development|verification) ;;
  *)
    save_snapshot
    jq -n '{decision:"block", reason:"⛔ [bash-gate] workflow_phase가 허용되지 않는 값입니다."}'
    exit 0 ;;
esac

# CHECK 2: planning → BLOCK
if [ "$WORKFLOW_PHASE" = "planning" ]; then
  save_snapshot
  jq -n '{
    decision: "block",
    reason: "⛔ [bash-gate] Planning 단계에서 Bash를 통한 파일 쓰기가 차단되었습니다. Q&A 완료 후 계획 승인을 받으세요."
  }'
  exit 0
fi

# CHECK 3: plan_approved + plan.md
if [ "$PLAN_APPROVED" != "true" ]; then
  save_snapshot
  jq -n '{
    decision: "block",
    reason: "⛔ [bash-gate] 계획 미승인 상태에서 Bash를 통한 파일 쓰기가 차단되었습니다. /dev-bounce로 계획을 승인받으세요."
  }'
  exit 0
fi

if [ ! -f "${TASK_DIR}/plan.md" ]; then
  save_snapshot
  jq -n '{
    decision: "block",
    reason: "⛔ [bash-gate] plan.md가 없는 상태에서 Bash를 통한 파일 쓰기가 차단되었습니다."
  }'
  exit 0
fi

# SIMPLE 모드: plan_approved + plan.md 존재만으로 통과
if [ "$MODE" = "simple" ]; then
  exit 0
fi

# --- 이하 NORMAL 모드 전용 ---

# CHECK 4: development + team_name
if [ "$WORKFLOW_PHASE" = "development" ] && [ -z "$TEAM_NAME" ]; then
  save_snapshot
  jq -n '{
    decision: "block",
    reason: "⛔ [bash-gate] 팀 미구성 상태에서 Bash를 통한 파일 쓰기가 차단되었습니다."
  }'
  exit 0
fi

# CHECK 5-6: team config + members
if [ "$WORKFLOW_PHASE" = "development" ]; then
  TEAM_CONFIG="$HOME/.claude/teams/${TEAM_NAME}/config.json"
  if [ ! -f "$TEAM_CONFIG" ]; then
    save_snapshot
    jq -n '{
      decision: "block",
      reason: "⛔ [bash-gate] 팀 디렉토리 미존재 상태에서 Bash를 통한 파일 쓰기가 차단되었습니다."
    }'
    exit 0
  fi

  MEMBER_COUNT=$(jq -r '.members | length' "$TEAM_CONFIG" 2>/dev/null)
  if [ -z "$MEMBER_COUNT" ] || [ "$MEMBER_COUNT" -lt 1 ] 2>/dev/null; then
    save_snapshot
    jq -n '{
      decision: "block",
      reason: "⛔ [bash-gate] 팀 멤버 부족 상태에서 Bash를 통한 파일 쓰기가 차단되었습니다."
    }'
    exit 0
  fi
fi

# CHECK 6.5: development + step=0 방어
if [ "$WORKFLOW_PHASE" = "development" ]; then
  if [ "$CURRENT_DEV_PHASE" -le 0 ] 2>/dev/null || [ "$CURRENT_STEP" -le 0 ] 2>/dev/null; then
    save_snapshot
    jq -n '{decision:"block", reason:"⛔ [bash-gate] development이지만 dev_phase/step 미설정"}'
    exit 0
  fi
fi

# CHECK 7: step 검증
if [ "$CURRENT_DEV_PHASE" -gt 0 ] 2>/dev/null && [ "$CURRENT_STEP" -gt 0 ] 2>/dev/null; then
  DEV_PHASE_KEY="$CURRENT_DEV_PHASE"
  STEP_KEY="$CURRENT_STEP"

  PHASE_FOLDER=$(jq -r ".dev_phases[\"$DEV_PHASE_KEY\"].folder // \"\"" "$STATE_FILE" 2>/dev/null)

  if [ -n "$PHASE_FOLDER" ]; then
    PHASE_DIR="${TASK_DIR}/${PHASE_FOLDER}"

    # CHECK 7a: phase.md 존재 검증
    if [ ! -f "${PHASE_DIR}/phase.md" ]; then
      save_snapshot
      jq -n --arg phase "$DEV_PHASE_KEY" '{
        decision: "block",
        reason: ("⛔ [bash-gate] Dev Phase " + $phase + "의 phase.md가 존재하지 않습니다. Lead가 phase.md를 먼저 생성해야 합니다.")
      }'
      exit 0
    fi

    PREV_STEP=$((CURRENT_STEP - 1))
    if [ "$PREV_STEP" -gt 0 ]; then
      PREV_STEP_FILE="${PHASE_DIR}/step-${PREV_STEP}.md"

      if [ ! -f "$PREV_STEP_FILE" ]; then
        save_snapshot
        jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
          decision: "block",
          reason: ("⛔ [bash-gate] Dev Phase " + $phase + " Step " + $step + " 문서 미존재. Bash 파일 쓰기 차단.")
        }'
        exit 0
      fi

      if ! grep -q '✅' "$PREV_STEP_FILE" 2>/dev/null; then
        save_snapshot
        jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$PREV_STEP" '{
          decision: "block",
          reason: ("⛔ [bash-gate] Dev Phase " + $phase + " Step " + $step + " 테스트 미통과. Bash 파일 쓰기 차단.")
        }'
        exit 0
      fi
    fi

    CURRENT_STEP_FILE="${PHASE_DIR}/step-${STEP_KEY}.md"

    if [ ! -f "$CURRENT_STEP_FILE" ]; then
      save_snapshot
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
        decision: "block",
        reason: ("⛔ [bash-gate] Dev Phase " + $phase + " Step " + $step + " step.md 미존재. Bash 파일 쓰기 차단.")
      }'
      exit 0
    fi

    if ! grep -E '^\| *TC-[0-9]+ *\| *[^ |]' "$CURRENT_STEP_FILE" >/dev/null 2>&1; then
      save_snapshot
      jq -n --arg phase "$DEV_PHASE_KEY" --arg step "$STEP_KEY" '{
        decision: "block",
        reason: ("⛔ [bash-gate] Dev Phase " + $phase + " Step " + $step + " TC 미정의. Bash 파일 쓰기 차단.")
      }'
      exit 0
    fi
  fi
fi

# 모든 검증 통과 — 스냅샷 불필요 (gate 조건 충족)
# --- ai-bouncer end ---

exit 0
