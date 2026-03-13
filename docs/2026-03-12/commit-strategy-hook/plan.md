# commit_strategy hook 강제

## Context

현재 `bash-gate.sh`에서 모든 `git` 명령을 무조건 통과시킨다 (line 28-30).
`commit_strategy` 설정(per-step/per-phase/none)은 SKILL.md 프롬프트에만 의존 → hook 강제 없음.
git commit/push를 commit_strategy에 맞게 hook에서 차단하도록 변경.

## 변경 파일

1. `hooks/bash-gate.sh` — git commit/push 감지 + commit_strategy 분기
2. `tests/e2e-modes.sh` — commit_strategy E2E 시나리오 추가 (찐 E2E)

## 구현: bash-gate.sh

### line 27-30 변경

기존:
```bash
# 2. git 명령어 → exit 0 (git commit, push 등)
if echo "$CMD" | grep -qE '^\s*git\b'; then
  exit 0
fi
```

변경:
```bash
# 2. git 명령어 분기
if echo "$CMD" | grep -qE '^\s*git\b'; then
  # git commit/push → commit_strategy 검증
  if echo "$CMD" | grep -qE '\bgit\s+(commit|push)\b'; then
    # commit_strategy 검증 블록으로 이동 (아래)
    :
  else
    # 나머지 git 명령 (status, add, diff 등) → 통과
    exit 0
  fi
fi
```

### commit_strategy 검증 블록 (git 분기 직후, CHECK 1.5 전에 삽입)

```bash
# --- commit_strategy 검증 (git commit/push) ---
if echo "$CMD" | grep -qE '^\s*git\s+(commit|push)\b'; then
  REPO_ROOT_CS=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  CONFIG_CS="$REPO_ROOT_CS/.claude/ai-bouncer/config.json"
  COMMIT_STRATEGY=$(jq -r '.commit_strategy // "per-step"' "$CONFIG_CS" 2>/dev/null || echo "per-step")

  # config.json 없으면 통과
  [ ! -f "$CONFIG_CS" ] && exit 0

  # none → 항상 block
  if [ "$COMMIT_STRATEGY" = "none" ]; then
    jq -n '{decision:"block", reason:"⛔ [bash-gate] commit_strategy=none: 커밋이 차단됩니다. 수동 관리 모드."}'
    exit 0
  fi

  # .active 탐색 (resolve-task.sh 패턴)
  SCRIPT_DIR_CS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR_CS/lib/resolve-task.sh"

  # .active 없으면 gate 비활성 → 통과
  [ -z "$TASK_NAME" ] && exit 0

  # state.json 없으면 통과
  [ -f "$STATE_FILE" ] || exit 0

  CS_WORKFLOW=$(jq -r '.workflow_phase // "done"' "$STATE_FILE" 2>/dev/null)
  CS_MODE=$(jq -r '.mode // "normal"' "$STATE_FILE" 2>/dev/null)

  # verification/done → 항상 허용
  case "$CS_WORKFLOW" in
    verification|done) exit 0 ;;
  esac

  # planning → block (아직 개발 안 시작)
  if [ "$CS_WORKFLOW" = "planning" ]; then
    jq -n '{decision:"block", reason:"⛔ [bash-gate] planning 단계에서는 커밋할 수 없습니다."}'
    exit 0
  fi

  # simple 모드 → development이면 허용 (step 검증 없음)
  if [ "$CS_MODE" = "simple" ]; then
    exit 0
  fi

  # --- NORMAL 모드 + development ---
  CS_PHASE=$(jq -r '.current_dev_phase // 0' "$STATE_FILE" 2>/dev/null)
  CS_STEP=$(jq -r '.current_step // 0' "$STATE_FILE" 2>/dev/null)
  CS_PHASE_FOLDER=$(jq -r ".dev_phases[\"$CS_PHASE\"].folder // \"\"" "$STATE_FILE" 2>/dev/null)

  [ -z "$CS_PHASE_FOLDER" ] && exit 0

  STEP_FILE="${TASK_DIR}/${CS_PHASE_FOLDER}/step-${CS_STEP}.md"

  if [ "$COMMIT_STRATEGY" = "per-step" ]; then
    # 현재 step의 step-M.md에 ✅ 있어야 허용
    if [ -f "$STEP_FILE" ] && grep -q '✅' "$STEP_FILE" 2>/dev/null; then
      exit 0
    fi
    jq -n --arg p "$CS_PHASE" --arg s "$CS_STEP" \
      '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-step: Phase " + $p + " Step " + $s + " 미완료. 테스트 통과 후 커밋하세요.")}'
    exit 0
  fi

  if [ "$COMMIT_STRATEGY" = "per-phase" ]; then
    # 현재 phase의 마지막 step 찾기
    LAST_STEP=$(jq -r ".dev_phases[\"$CS_PHASE\"].steps | keys | map(tonumber) | max" "$STATE_FILE" 2>/dev/null)
    LAST_STEP_FILE="${TASK_DIR}/${CS_PHASE_FOLDER}/step-${LAST_STEP}.md"

    if [ -f "$LAST_STEP_FILE" ] && grep -q '✅' "$LAST_STEP_FILE" 2>/dev/null; then
      exit 0
    fi
    jq -n --arg p "$CS_PHASE" --arg ls "$LAST_STEP" \
      '{decision:"block", reason:("⛔ [bash-gate] commit_strategy=per-phase: Phase " + $p + " 마지막 Step " + $ls + " 미완료. Phase 완료 후 커밋하세요.")}'
    exit 0
  fi

  # 알 수 없는 strategy → 통과 (하위 호환)
  exit 0
fi
```

## 구현: E2E 테스트 (e2e-modes.sh에 Persona G 추가)

`e2e-modes.sh`의 기존 패턴 따름:
1. `setup_fake_env`로 tmpdir + fake git repo 생성
2. `run_install_modes`로 실제 install.sh 실행
3. docs/ 구조 + state.json + step-*.md 생성
4. 설치된 bash-gate.sh에 `git commit` 명령 stdin으로 전달
5. decision 검증

### Persona G: commit_strategy 유저

```bash
persona_g() {
  # G-1: per-step + step 미완료 + git commit → BLOCK
  # G-2: per-step + step 완료(✅) + git commit → ALLOW
  # G-3: per-phase + 중간 step + git commit → BLOCK
  # G-4: per-phase + 마지막 step 완료 + git commit → ALLOW
  # G-5: none + git commit → BLOCK
  # G-6: git status (비 commit) → ALLOW
  # G-7: verification 단계 + git commit → ALLOW
  # G-8: .active 없음 + git commit → ALLOW (gate 비활성)
  # G-9: simple 모드 + development + git commit → ALLOW
  # G-10: planning + git commit → BLOCK
}
```

총 10개 TC. 각각 실제 install.sh로 설치된 hook 사용.

## 검증

```bash
bash tests/e2e-modes.sh
```

기존 Persona A~F (45건) + Persona G (10건) = 총 55건 통과.
