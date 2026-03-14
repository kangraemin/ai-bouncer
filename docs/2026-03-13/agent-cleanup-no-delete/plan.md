# agent 파일 삭제 + subagent gate 우회 버그 수정

## Context
두 가지 버그:
1. **install.sh agent 파일 삭제**: 소스에서 제거된 agent 파일을 설치 프로젝트에서 `rm -f` → 사용자 agent 파일(proxy-analyzer.md 등) 손실
2. **subagent gate 우회**: nested subagent(Lead→Dev) 스폰 시 SubagentStart hook 미발화 가능 → Dev session_id 미등록 → resolve-task.sh TASK_NAME="" → plan-gate/bash-gate 모든 검증 스킵 → phase/step 문서 없이 개발 진행

증거: claudeInspector/docs/2026-03-13/ — 7개 태스크 전부 phase/step/verification 문서 0개로 완료됨.

## 변경 파일별 상세

### 1. `install.sh` (344-356행)
- **변경 이유**: 소스에 없는 agent 파일을 삭제하지 않고 안내만 출력
- **Before**:
```bash
# 소스에 없는 설치된 agent 파일 삭제 (manifest에 기록된 파일만 대상)
for installed in "$TARGET_DIR/agents/"*.md; do
  [ -f "$installed" ] || continue
  rel_path="agents/$(basename "$installed")"
  # manifest에 없으면 사용자가 직접 추가한 파일 → 스킵
  if [ -f "$MANIFEST" ] && ! python3 -c "import json,sys; files=json.load(open(sys.argv[1])).get('files',[]); sys.exit(0 if sys.argv[2] in files else 1)" "$MANIFEST" "$rel_path" 2>/dev/null; then
    continue
  fi
  if [ ! -f "$PACKAGE_DIR/agents/$(basename "$installed")" ]; then
    rm -f "$installed"
    warn "$(basename "$installed") 삭제 (소스에서 제거됨)"
  fi
done
```
- **After**:
```bash
# 소스에서 제거된 agent 파일: 안내만 출력, 파일 유지
# (manifest는 INSTALLED_FILES 기반으로 자동 갱신되므로 별도 처리 불필요)
for installed in "$TARGET_DIR/agents/"*.md; do
  [ -f "$installed" ] || continue
  if [ ! -f "$PACKAGE_DIR/agents/$(basename "$installed")" ]; then
    info "$(basename "$installed") — 소스에서 제거됨 (파일 유지)"
  fi
done
```

### 2. `hooks/lib/resolve-task.sh` (124-128행 뒤 추가)
- **변경 이유**: 미등록 subagent(session_id 매칭 실패)도 활성 development/verification 태스크의 gate 검증 대상으로 포함
- **Before** (파일 끝):
```bash
# 결과 설정
if [ -n "$TASK_NAME" ]; then
  TASK_DIR="${DOCS_BASE}/${TASK_NAME}"
  STATE_FILE="${TASK_DIR}/state.json"
fi
```
- **After**:
```bash
# 결과 설정
if [ -n "$TASK_NAME" ]; then
  TASK_DIR="${DOCS_BASE}/${TASK_NAME}"
  STATE_FILE="${TASK_DIR}/state.json"
fi

# Fallback: 매칭 실패 시 활성 development/verification 태스크를 read-only로 적용
# → 미등록 subagent도 gate 검증 대상이 됨 (nested subagent 우회 방지)
if [ -z "$TASK_NAME" ] && [ -n "$SESSION_ID" ]; then
  _fallback_find_active() {
    local base="$1"
    [ -d "$base" ] || return 1
    for af in "$base"/*/.active; do
      [ -f "$af" ] || continue
      local td sf phase
      td=$(dirname "$af")
      sf="${td}/state.json"
      [ -f "$sf" ] || continue
      phase=$(jq -r '.workflow_phase // ""' "$sf" 2>/dev/null)
      case "$phase" in
        development|verification)
          TASK_NAME=$(basename "$td")
          DOCS_BASE="$base"
          TASK_DIR="$td"
          STATE_FILE="$sf"
          return 0 ;;
      esac
    done
    return 1
  }

  # 날짜별 구조
  if [ -d "docs" ]; then
    for dd in docs/*/; do
      [ -d "$dd" ] || continue
      _fallback_find_active "$dd" && break
    done
  fi

  # persistent 경로
  if [ -z "$TASK_NAME" ]; then
    _fallback_find_active "$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs"
  fi

  # flat 구조 (하위 호환)
  if [ -z "$TASK_NAME" ]; then
    _fallback_find_active "docs"
  fi
fi
```
- **영향 범위**: plan-gate.sh, bash-gate.sh 모두 resolve-task.sh를 source하므로 자동 적용

### 2-1. `hooks/plan-gate.sh` (93-130행) — agent_mode 3-way 분기
- **변경 이유**: team/subagent/single 모드별 명확한 검증 분리
- **Before**:
```bash
# agent_mode 읽기 (config.json에서)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
AGENT_MODE=$(jq -r '.agent_mode // "team"' "$REPO_ROOT/.claude/ai-bouncer/config.json" 2>/dev/null || echo "team")

# CHECK 4/5/6: team 모드에서만 팀 구성 검증
if [ "$AGENT_MODE" = "team" ]; then
  # CHECK 4: development + team_name 비어있음 → BLOCK
  ...
  # CHECK 5: development + team config.json 미존재 → BLOCK
  ...
  # CHECK 6: team members < 1 → BLOCK
  ...
fi
```
- **After**:
```bash
# agent_mode 읽기 (config.json에서)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
AGENT_MODE=$(jq -r '.agent_mode // "team"' "$REPO_ROOT/.claude/ai-bouncer/config.json" 2>/dev/null || echo "team")

# agent_mode별 검증 분기
case "$AGENT_MODE" in
  team)
    # CHECK 4: development + team_name 비어있음 → BLOCK
    if [ "$WORKFLOW_PHASE" = "development" ] && [ -z "$TEAM_NAME" ]; then
      jq -n '{decision:"block", reason:"⛔ [team] 팀이 구성되지 않았습니다. TeamCreate로 팀을 먼저 생성하세요."}'
      exit 0
    fi
    # CHECK 5: team config.json 미존재 → BLOCK
    if [ "$WORKFLOW_PHASE" = "development" ]; then
      TEAM_CONFIG="$HOME/.claude/teams/${TEAM_NAME}/config.json"
      if [ ! -f "$TEAM_CONFIG" ]; then
        jq -n '{decision:"block", reason:"⛔ [team] 팀 디렉토리가 존재하지 않습니다."}'
        exit 0
      fi
      # CHECK 6: team members < 1 → BLOCK
      MEMBER_COUNT=$(jq -r '.members | length' "$TEAM_CONFIG" 2>/dev/null)
      MEMBER_COUNT=${MEMBER_COUNT:-0}
      if [ "$MEMBER_COUNT" -lt 1 ] 2>/dev/null; then
        jq -n '{decision:"block", reason:"⛔ [team] 팀 멤버가 없습니다."}'
        exit 0
      fi
    fi
    ;;
  subagent)
    # subagent: team 구성 불필요, 위임 등록 검증은 resolve-task.sh fallback이 처리
    ;;
  single)
    # single: Main Claude가 직접 수행, 팀/에이전트 검증 불필요
    ;;
esac
```

### 2-2. `hooks/bash-gate.sh` (354-393행) — 동일하게 3-way 분기
- **변경 이유**: plan-gate.sh와 동일한 agent_mode 3-way case 분기 적용
- **Before**: `if [ "$AGENT_MODE" = "team" ]; then ... fi`
- **After**: plan-gate.sh와 동일한 `case "$AGENT_MODE" in team|subagent|single)` 구조

### 3. `tests/e2e-full.sh` — agent 파일 보존 테스트 추가 (섹션 4 "Update" 뒤)
- **변경 이유**: install.sh 변경 검증
- **추가 내용** (242행 `rm -f` 뒤, 섹션 5 Uninstall 앞):
```bash
# 소스에 없는 agent 파일이 update 시 삭제되지 않는지 검증
echo "former-bouncer-agent" > "$TARGET/agents/old-removed-agent.md"
# manifest에 등록 (이전 버전에서 설치된 것처럼)
python3 -c "
import json
m = json.load(open('$TARGET/ai-bouncer/manifest.json'))
m['files'].append('agents/old-removed-agent.md')
json.dump(m, open('$TARGET/ai-bouncer/manifest.json', 'w'), indent=2)
"
(cd "$REPO_DIR" && CI=true bash "$SRC_DIR/install.sh" --update) 2>&1 | tail -3
assert_file "update 후 소스에 없는 agent 파일 유지됨" "$TARGET/agents/old-removed-agent.md"
rm -f "$TARGET/agents/old-removed-agent.md"
```

### 4. `tests/e2e-hooks.sh` — 미등록 subagent fallback 테스트 추가 (섹션 7 "subagent 모드" 뒤)
- **변경 이유**: resolve-task.sh fallback 로직 검증
- **추가 섹션**:
```bash
# ─── 7.5. 미등록 subagent fallback (resolve-task.sh) ──────
echo "─── 미등록 subagent fallback ───"

UNREGISTERED_SID="unregistered-sub-$(date +%s)"

# UF-1: 미등록 subagent + 활성 development 태스크 → plan-gate 차단 (phase.md 없으므로)
FALLBACK_PHASES='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_subagent "$FALLBACK_PHASES" 1 1
# approved 파일에 등록 안 함 — 미등록 subagent 시뮬레이션
rm -f /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_block "UF-1: 미등록 subagent + development → plan-gate 차단" "$R"

# UF-2: 미등록 subagent + 활성 development 태스크 → bash-gate 차단
R=$(run_hook bash-gate.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo test > file.txt\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_block "UF-2: 미등록 subagent + development → bash-gate 차단" "$R"
cleanup_subagent

# UF-3: 미등록 subagent + 활성 태스크 없음 → 통과
rm -f "$ACTIVE_FILE"
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-3: 미등록 subagent + 활성 태스크 없음 → 통과" "$R"

# UF-4: 미등록 subagent + planning 태스크만 → 통과 (fallback은 dev/verification만)
setup "simple" "planning" "false"
# 다른 .active들 임시 숨기기
OTHER_ACTIVES_UF=()
while IFS= read -r -d '' af; do
  [ "$af" = "$ACTIVE_FILE" ] && continue
  OTHER_ACTIVES_UF+=("$af")
  mv "$af" "${af}.bak-uf"
done < <(find docs -name ".active" -print0 2>/dev/null)
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-4: 미등록 subagent + planning만 → 통과 (fallback 안 됨)" "$R"
for af in "${OTHER_ACTIVES_UF[@]}"; do
  mv "${af}.bak-uf" "$af" 2>/dev/null || true
done

# UF-5: 미등록 subagent + 정상 아티팩트 모두 존재 → 통과
FALLBACK_PHASES_FULL='{"1":{"name":"test","folder":"phase-1-test","steps":{"1":{"title":"Step 1"}}}}'
setup_subagent "$FALLBACK_PHASES_FULL" 1 1
mkdir -p "$TASK_DIR/phase-1-test"
printf "# Phase 1\n\n## 목표\n- test\n\n## 범위\n- test\n\n## Steps\n- Step 1\n" > "$TASK_DIR/phase-1-test/phase.md"
printf "| TC-1 | test | expected |\n" > "$TASK_DIR/phase-1-test/step-1.md"
rm -f /tmp/.ai-bouncer-approved-agents
R=$(run_hook plan-gate.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/test.py\"},\"session_id\":\"$UNREGISTERED_SID\"}")
assert_pass "UF-5: 미등록 subagent + 정상 아티팩트 → 통과" "$R"
cleanup_subagent

echo ""
```

## 검증
- `bash tests/e2e-full.sh` — 기존 + 새 테스트 통과
- `bash tests/e2e-hooks.sh` — 기존 + 새 테스트 통과
