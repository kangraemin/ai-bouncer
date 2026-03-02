---
description: 구조화된 개발 flow 실행 (ai-bouncer v4)
---

# /dev

Planning Team → 계획 수립 → 승인 → Dev Team → 개발 → 3회 연속 검증 → 완료.
계획 승인 없이는 코드를 수정하지 않는다.

---

## 컨텍스트 복원 (세션 재시작 시)

시작 전 `docs/.active` 파일 확인:

```bash
cat docs/.active 2>/dev/null
```

- 활성 작업 있음 → 해당 `docs/<task>/state.json` 읽어 `workflow_phase` 확인 후 해당 Phase부터 재개
- 활성 작업 없음 → 새 작업 시작 (Phase 0부터)

---

## Phase 0: 인텐트 판별

1. intent 에이전트 스폰
2. 요청 원문 전달 → `[INTENT:*]` 수신
3. 처리:
   - `[INTENT:일반응답]` → 일반 응답 후 종료
   - `[INTENT:내용불충분]` → 사용자에게 되물음 후 종료
   - `[INTENT:개발요청]` → Phase 1 진행
4. intent 에이전트 shutdown

---

## Phase 1: Planning Team + Q&A 루프

### 1-0. TASK_DIR 초기화

요청에서 작업 이름 추출 (영어 소문자, 하이픈 구분):

```bash
TASK_NAME="user-auth"  # 예: 요청에서 핵심 키워드 추출
TASK_DIR="docs/${TASK_NAME}"
mkdir -p "${TASK_DIR}"

# docs/.active 업데이트
echo "${TASK_NAME}" > docs/.active

# state.json 초기화
python3 << 'PYEOF'
import json, os
task_dir = os.environ.get('TASK_DIR', 'docs/current')
os.makedirs(task_dir, exist_ok=True)
state = {
    "workflow_phase": "planning",
    "planning": {"no_question_streak": 0},
    "plan_approved": False,
    "current_dev_phase": 0,
    "current_step": 0,
    "dev_phases": {},
    "verification": {"rounds_passed": 0}
}
with open(os.path.join(task_dir, 'state.json'), 'w') as f:
    json.dump(state, f, indent=2)
print(f"state.json initialized at {task_dir}")
PYEOF
```

### 1-1. Planning Team 구성

```
TeamCreate: planning-<task>
  - planner-lead (planner-lead.md) — 리드
  - planner-dev (planner-dev.md) — 기술 관점
  - planner-qa (planner-qa.md) — 품질 관점
```

팀에게 전달: 요청 원문 + TASK_DIR + 관련 코드 컨텍스트

### 1-2. Q&A 루프

```
while true:
  a. planner-lead에게 "질문 생성 시도" 요청
  b. [QUESTIONS] 수신:
     - 사용자에게 질문 제시 (번호 목록)
     - 답변 수신
     - planner-lead에게 답변 전달
     - state.json no_question_streak = 0 업데이트
     - a로 돌아감
  c. [NO_QUESTIONS] 수신:
     - no_question_streak += 1 (state.json 업데이트)
     - streak < 3 → a로 돌아감 (재시도)
     - streak >= 3 → 다음 단계
```

### 1-3. 계획 확정

planner-lead에게 "계획 확정" 요청 → `[PLAN:완성]` + `{TASK_DIR}/plan.md` 생성 확인.

Planning 팀 shutdown.

### 1-4. 계획 사용자에게 표시

`{TASK_DIR}/plan.md` 내용 표시:

```
[PLAN:승인대기]

<plan.md 내용>

수정 요청이 있으면 말씀해주세요. 승인하시면 개발을 시작합니다.
```

---

## Phase 2: 계획 승인 처리

승인 신호 감지: `승인`, `시작`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`

```bash
python3 << 'PYEOF'
import json, os
task_dir = os.environ.get('TASK_DIR', 'docs/current')
f = os.path.join(task_dir, 'state.json')
with open(f) as fp: s = json.load(fp)
s['plan_approved'] = True
s['workflow_phase'] = 'development'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
print('plan_approved = true')
PYEOF
```

`[PLAN:승인됨]` 출력 → Phase 3 진행

---

## Phase 3: Dev Team 구성 + 개발

### 3-1. Lead 에이전트 스폰

TASK_DIR 전달하여 Lead 스폰.

Lead가 수행:
1. `{TASK_DIR}/plan.md` 읽기
2. 팀 규모 종합 판단 → `[TEAM:solo|duo|team]` 출력
3. 고수준 계획 → 개발 Phase 분해 → `[DEV_PHASES:확정]`
4. state.json `dev_phases` 초기화

### 3-2. 팀 구성

| Lead 출력 | 팀 구성 |
|---|---|
| `[TEAM:solo]` | Lead가 Dev + QA 역할 직접 수행 |
| `[TEAM:duo]` | Dev 에이전트 1명 스폰 |
| `[TEAM:team]` | Dev + QA 에이전트 각 1명 스폰 |

### 3-3. TDD 개발 루프 (Phase/Step 반복)

각 개발 Phase의 각 Step마다:

```
5-1. QA: docs/<task>/phase-N-*/step-M.md에 TC 먼저 작성
     → [STEP:N:테스트정의완료] 출력
     → state.json test_defined = true

5-2. Dev: TC 통과할 최소 코드 구현
          docs/<task>/phase-N-*/step-M.md 구현 내용 업데이트
     → [STEP:N:개발완료]
       빌드 명령: <명령어>
       결과: ✅ 성공

5-3. QA: 테스트 실행
     → [STEP:N:테스트통과]
       명령어: <명령어>
       결과: N/N 통과
     → state.json passed = true, current_step++

     실패 시 → Dev에 반려 → 5-2 반복
```

### 3-4. 블로킹 에스컬레이션

Dev/QA가 구현 불가 또는 기획 질문이 생긴 경우:

```
[STEP:N:블로킹:기술불가] 또는 [STEP:N:블로킹:기획질문]
```

처리:
- `기술불가`: 사용자에게 보고, 범위 변경 필요하면 Phase 1 재시작
- `기획질문`: state.json `workflow_phase = "planning"` 리셋 → Phase 1 재시작

### 3-5. 모든 Step 완료

Lead가 `[ALL_STEPS:완료]` 출력 → Phase 4 진행

---

## Phase 4: 연속 3회 검증 루프

1. verifier 에이전트 스폰 (TASK_DIR 전달)
2. verifier가 검증 루프 실행 (시도 횟수 제한 없음)
3. `[VERIFICATION:N:실패:PHASE-P-STEP-M]` 수신:
   - Dev/QA에게 해당 Step 재작업 지시
   - 재작업 완료 후 verifier에게 "재검증 시작" 요청
4. `[DONE]` 수신 (rounds_passed = 3):
   - verifier + 전체 팀 shutdown
   - `docs/.active` 파일 삭제 (또는 빈 파일로)
   - 사용자에게 완료 보고

---

## 주의사항

- `[PLAN:승인됨]` 없이 코드 수정 시도 → plan-gate.sh가 차단
- 이전 Step 테스트 미통과 상태에서 다음 Step 코드 수정 → plan-gate.sh가 차단
- QA TC 정의 전 코드 작성 시도 → plan-gate.sh가 차단
- 검증 미완료(rounds_passed < 3) 상태에서 응답 종료 → completion-gate.sh가 차단
- 커밋: 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md`
- Step 완료 = 즉시 커밋 + 푸시
