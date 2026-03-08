---
name: dev-bounce
description: 코드 수정, 기능 구현, 버그 수정, 리팩토링, 파일 변경 등 모든 개발 작업에 반드시 사용해야 하는 구조화된 워크플로우. 사용자가 코드 변경을 요청하면 항상 이 스킬을 먼저 호출할 것. 복잡도에 따라 SIMPLE/NORMAL 모드 자동 분기. plan-gate hook이 이 스킬 없이 코드 수정을 차단하므로 우회 불가.
---

# dev-bounce

복잡도에 따라 두 가지 모드로 분기:
- **SIMPLE**: Main Claude가 직접 계획·개발·검증 (팀/phase/step 없음)
- **NORMAL**: Planning Team → 계획 수립 → 승인 → Dev Team → TDD 개발 → 3회 연속 검증

계획 승인 없이는 코드를 수정하지 않는다.

**주의: plan-gate.sh + bash-gate.sh(2-layer)는 아티팩트를 직접 검증합니다. Write/Edit뿐 아니라 Bash를 통한 파일 쓰기도 차단됩니다.**

---

## 컨텍스트 복원 (세션 재시작 시)

시작 전 활성 작업 확인 (세션별 격리 — `docs/YYYY-MM-DD/<task>/.active` 방식):

```bash
# docs/YYYY-MM-DD/<task>/.active 스캔
TASK_NAME=""
for date_dir in docs/*/; do
  [ -d "$date_dir" ] || continue
  for active_file in "$date_dir"*/.active; do
    [ -f "$active_file" ] || continue
    task_folder=$(basename "$(dirname "$active_file")")
    task_dir="$(dirname "$active_file")"
    state_json="${task_dir}/state.json"
    [ -f "$state_json" ] || continue
    TASK_NAME="$task_folder"
    STATE_JSON="$state_json"
    TASK_DIR="$task_dir"
    break 2
  done
done
```

- 활성 작업 있음 → 해당 `state.json` 읽어 `workflow_phase` 확인 후 해당 Phase부터 재개
- 활성 작업 없음 → 새 작업 시작 (Phase 0부터)

---

## Phase 0: 인텐트 판별

1. intent 에이전트 스폰
2. 요청 원문 전달 → `[INTENT:*]` 수신
3. 처리:
   - `[INTENT:일반응답]` → 일반 응답 후 종료
   - `[INTENT:내용불충분]` → AskUserQuestion으로 개발 내용 구체화 요청 후 Phase 0 재시도
     (예: "어떤 기능/버그를 개발·수정할지 구체적으로 알려주세요.")
     ⚠️ "개발 작업으로 처리할까요?" 같은 yes/no 확인 질문 절대 금지.
   - `[INTENT:개발요청]` → Phase 0-B 진행
4. intent 에이전트 shutdown

### Phase 0-B: 복잡도 판별

`[INTENT:개발요청]` 수신 후 Main Claude가 직접 복잡도 판별:

| 기준 | SIMPLE | NORMAL |
|------|--------|--------|
| 변경 파일 수 | 1~3개 예상 | 4개 이상 또는 불확실 |
| 변경 범위 | 단일 기능/버그/설정 | 여러 모듈에 걸친 변경 |
| 구현 방향 | 명확 | 설계 토론 필요 |
| 테스트 | 기존 테스트로 검증 가능 | 새 테스트 케이스 필요 |

판별 후 TASK_DIR 초기화 + state.json 생성:

TASK_DIR 초기화 (Python으로 실행):

1. `TASK_NAME`: 요청에서 핵심 키워드 추출 (예: `user-auth`)
2. `docs_base`: `docs/YYYY-MM-DD/` (프로젝트 로컬)
3. `task_dir`: `{docs_base}/{TASK_NAME}`
4. `.active` 파일 생성 (빈 파일 — hook이 session_id를 자동 claim)
5. `state.json` 생성:

```json
{
  "workflow_phase": "planning",
  "mode": "simple 또는 normal",
  "planning": {"no_question_streak": 0},
  "plan_approved": false,
  "team_name": "",
  "current_dev_phase": 0,
  "current_step": 0,
  "dev_phases": {},
  "verification": {"rounds_passed": 0},
  "task_dir": "docs/YYYY-MM-DD/task-name",
  "active_file": "docs/YYYY-MM-DD/task-name/.active"
}
```

- `mode: simple` → Phase S1 진행
- `mode: normal` → Phase 1 진행

---

## SIMPLE 모드

### Phase S1: 계획 수립

Main Claude가 직접 수행 (팀 스폰 없음):

1. EnterPlanMode 호출
2. 관련 코드 탐색 (Read/Grep/Glob)
3. 필요시 사용자에게 AskUserQuestion 1~2회
4. 계획 내용을 plan mode 내부 plan 파일에 정리
5. ExitPlanMode 호출 (plan mode 종료)
6. `{TASK_DIR}/plan.md` 직접 작성 (plan mode 밖에서 Write 사용):
   ```markdown
   # <작업 제목>
   ## 변경 사항
   - 파일: 변경 내용
   ## 검증
   - 검증 방법
   ```
7. 사용자에게 계획 표시 + 승인 대기

### Phase S2: 승인 + 개발

승인 신호 감지: `승인`, `시작`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`

승인 시 state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`
(hook이 이 두 플래그를 검증하므로 반드시 승인 후 업데이트해야 코드 수정이 가능)

#### TC 판단 + 작성

승인 후 plan.md의 검증 섹션을 확인하여 TC 작성 여부를 판단:

- **TC 작성 대상**: 테스트 가능한 항목이 있는 경우 (함수 동작, CLI 출력, API 응답 등)
  1. `{TASK_DIR}/tests.md`에 TC 작성:
     ```markdown
     ## TC-1: <테스트 이름>
     - 입력: ...
     - 기대결과: ...
     - 검증명령: `<실행할 명령어>`
     - 결과: (개발 후 기록)
     ```
  2. TC 기반으로 코드 개발
  3. 개발 완료 후 TC 실행 → tests.md에 결과(✅/❌) 기록

- **TC 스킵**: 테스트할 게 없는 경우 (설정 변경, 문서 수정, 단순 리팩토링 등)
  - `[TC:스킵]` 명시 후 바로 개발

Main Claude가 직접 코드 수정 (phase/step 구조 없이 자유롭게).

### Phase S3: 검증 + 완료

개발 완료 후:

1. 테스트 실행 (pytest, lint 등) — 1회 통과면 OK
2. 경량 검증: plan.md 대비 실제 변경 확인
   - `{TASK_DIR}/plan.md` 읽어 변경 예정 파일 파악
   - `git diff HEAD~1 --name-only`로 실제 변경 파일 확인
   - 계획됐으나 미변경 파일이 있으면 사용자에게 경고 표시 (차단은 안 함)
   - 간단한 체크리스트 출력:
     ```
     [경량 검증]
     ✅ 테스트 통과
     ✅/⚠️ plan.md 대비 변경 확인: N/M 파일 일치
     (⚠️ 미변경: 파일명 — 의도된 것인지 확인 필요)
     ```
3. active_file 삭제: `rm -f {active_file}`
4. state.json `workflow_phase`를 `"done"`으로 업데이트
5. 사용자에게 완료 보고

---

## NORMAL 모드

### Phase 1: Planning Team + Q&A 루프

#### 1-0. Planning Team 구성

> TASK_DIR은 Phase 0-B에서 이미 초기화됨. plan mode 진입 전에 팀부터 구성한다.
> (TeamCreate는 plan mode에서 사용 불가)

```
TeamCreate: planning-<task>
  - planner-lead (planner-lead.md) — 리드
  - planner-dev (planner-dev.md) — 기술 관점
  - planner-qa (planner-qa.md) — 품질 관점
```

팀에게 전달: 요청 원문 + TASK_DIR + 관련 코드 컨텍스트

#### 1-1. Plan Mode 진입

EnterPlanMode 호출 — Q&A + 계획 수립을 plan mode 안에서 진행한다.

#### 1-2. Q&A 루프

> ⚠️ **Q&A 루프 중 ExitPlanMode 절대 금지.**
> planner-lead로부터 질문을 받아 사용자에게 전달할 때는 반드시 **AskUserQuestion** 사용.
> ExitPlanMode는 계획 확정 후 **Phase 1-3에서만** 호출한다.
> ⚠️ **plan mode에서 Write/Edit 도구 사용 금지** — 자동으로 plan mode가 해제됨.

```
while true:
  a. planner-lead에게 "질문 생성 시도" 요청
  b. [QUESTIONS] 수신:
     - 사용자에게 질문 제시 → AskUserQuestion 사용 (ExitPlanMode 아님!)
     - 답변 수신
     - planner-lead에게 답변 전달
     - state.json no_question_streak = 0 업데이트
     - a로 돌아감
  c. [NO_QUESTIONS] 수신:
     - no_question_streak += 1 (state.json 업데이트)
     - streak < 3 → a로 돌아감 (재시도)
     - streak >= 3 → 다음 단계
```

#### 1-3. 계획 확정 + Plan Mode 종료

planner-lead에게 "계획 확정" 요청 → `[PLAN:완성]` 수신.
계획 내용을 plan mode 내부 plan 파일에 정리.
Planning 팀 shutdown.

ExitPlanMode 호출 (plan mode 종료).

#### 1-4. plan.md 저장 + 사용자에게 표시

plan mode 밖에서 `{TASK_DIR}/plan.md`에 Write tool로 저장.
(plan-gate.sh가 `*/plan.md` 경로를 예외 허용하므로 planning 단계에도 가능)
저장 후 파일 존재 확인.

`{TASK_DIR}/plan.md` 내용 표시:

```
[PLAN:승인대기]

<plan.md 내용>

수정 요청이 있으면 말씀해주세요. 승인하시면 개발을 시작합니다.
```

---

### Phase 2: 계획 승인 처리

승인 신호 감지: `승인`, `시작`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`

수정 요청 시: EnterPlanMode 재진입 → planner-lead에게 재작업 지시 → 1-2 Q&A 루프 재시작

승인 시 state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`

`[PLAN:승인됨]` 출력 → Phase 3 진행

---

### Phase 3: Dev Team 구성 + 개발

#### 3-1. Lead 에이전트 스폰

TeamCreate로 Dev Team 생성 후 TASK_DIR 전달하여 Lead 스폰.

Lead가 수행:
1. `{TASK_DIR}/plan.md` 읽기
2. 팀 규모 종합 판단 → `[TEAM:solo|duo|team]` 출력
3. 고수준 계획 → 개발 Phase 분해 → `[DEV_PHASES:확정]`
4. state.json `dev_phases` 초기화 + `team_name = '<TeamCreate 팀 이름>'` 설정

#### 3-2. 팀 구성

| Lead 출력 | 팀 구성 |
|---|---|
| `[TEAM:solo]` | Lead가 Dev + QA 역할 직접 수행 |
| `[TEAM:duo]` | Dev 에이전트 1명 스폰 |
| `[TEAM:team]` | Dev + QA 에이전트 각 1명 스폰 |

#### 3-3. TDD 개발 루프 (Phase/Step 반복)

각 개발 Phase의 각 Step마다:

```
5-1. QA: docs/<task>/phase-N-*/step-M.md에 TC 먼저 작성
     → [STEP:N:테스트정의완료] 출력

5-2. Dev: TC 통과할 최소 코드 구현
          docs/<task>/phase-N-*/step-M.md 구현 내용 업데이트
     → [STEP:N:개발완료]
       빌드 명령: <명령어>
       결과: ✅ 성공

5-3. QA: 테스트 실행
     → [STEP:N:테스트통과]
       명령어: <명령어>
       결과: N/N 통과
     → step-M.md 실제 결과에 ✅ 기록
     → state.json current_step++

     실패 시 → Dev에 반려 → 5-2 반복
```

#### 3-4. Step/Phase 완료 시 커밋

`.claude/ai-bouncer/config.json`에서 커밋 전략 확인 (프로젝트 로컬 경로):

```bash
python3 -c "
import json
cfg = json.load(open('.claude/ai-bouncer/config.json'))
print(cfg.get('commit_strategy','per-step'), cfg.get('commit_skill', False))
"
```

| commit_strategy | 커밋 시점 | commit_skill | 커밋 방법 |
|---|---|---|---|
| `per-step` | `[STEP:N:테스트통과]` 직후 | `true` | `/commit` 스킬 호출 |
| `per-step` | `[STEP:N:테스트통과]` 직후 | `false` | `git add` + `git commit` + `git push` |
| `per-phase` | 개발 Phase 마지막 Step 통과 후 | `true` | `/commit` 스킬 호출 |
| `per-phase` | 개발 Phase 마지막 Step 통과 후 | `false` | `git add` + `git commit` + `git push` |
| `none` | — | — | 커밋 스킵 (수동 관리) |

커밋 실패 시 다음 Step 진행 금지 — 원인 해결 후 재시도.

#### 3-5. 블로킹 에스컬레이션

Dev/QA가 구현 불가 또는 기획 질문이 생긴 경우:

```
[STEP:N:블로킹:기술불가] 또는 [STEP:N:블로킹:기획질문]
```

처리:
- `기술불가`: 사용자에게 보고, 범위 변경 필요하면 Phase 1 재시작
- `기획질문`: state.json `workflow_phase = "planning"` 리셋 → Phase 1 재시작

#### 3-6. 모든 Step 완료

Lead가 `[ALL_STEPS:완료]` 출력 → Phase 4 진행

---

### Phase 4: 연속 3회 검증 루프

Phase 4 시작 전 state.json `workflow_phase`를 `"verification"`으로 업데이트.
(completion-gate.sh가 verification 상태에서 3회 연속 통과 전 응답 종료를 차단)

1. verifier 에이전트 스폰 (TASK_DIR 전달)
2. verifier가 검증 루프 실행 (시도 횟수 제한 없음)
3. `[VERIFICATION:N:실패:PHASE-P-STEP-M]` 수신:
   - Dev/QA에게 해당 Step 재작업 지시
   - 재작업 완료 후 verifier에게 "재검증 시작" 요청
4. `[DONE]` 수신 (verifications/round-*.md 3개 연속 통과):
   - verifier + 전체 팀 shutdown
   - active_file 삭제: `rm -f {active_file}`
   - state.json `workflow_phase`를 `"done"`으로 업데이트
     ⚠️ task_dir 자체는 절대 삭제하지 않는다. 모든 문서 보존.
   - 사용자에게 완료 보고

---

## 주의사항

- plan-gate.sh는 아티팩트(파일/팀 디렉토리)를 직접 검증합니다. state.json 플래그 조작으로 gate를 우회할 수 없습니다.
- 2-layer Bash 방어: bash-gate.sh(PreToolUse)가 쓰기 패턴을 감지하여 사전 차단하고,
  bash-audit.sh(PostToolUse)가 git diff로 모든 파일 변경을 감지하여 무단 변경을 자동 복원합니다.
  어떤 방법으로든 Bash를 통한 gate 우회는 100% 차단됩니다.
- SIMPLE 모드에서는 team/phase/step 검증을 건너뛰지만, `plan_approved` 검증은 유지됩니다.
- `[PLAN:승인됨]` 없이 코드 수정 시도 → plan-gate.sh / bash-gate.sh가 차단
- NORMAL 모드: 이전 Step의 step-M.md에 ✅가 없으면 다음 Step 코드 수정 → plan-gate.sh / bash-gate.sh가 차단
- 검증 미완료(NORMAL: round-*.md 3개 연속 통과) 상태에서 응답 종료 → completion-gate.sh가 차단
- 커밋: 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md`
- 완료 후 task_dir 삭제 금지 — active_file(`docs/YYYY-MM-DD/<task>/.active`)만 삭제한다
- 세션 격리: `.active` 파일은 `docs/YYYY-MM-DD/<task>/.active`에 위치하며 session_id를 저장. hook이 자동으로 claim한다.
- docs 구조: `docs/YYYY-MM-DD/task-name/` — 날짜별로 태스크 문서를 구조화
- config.json 경로: `.claude/ai-bouncer/config.json` (프로젝트 로컬)
