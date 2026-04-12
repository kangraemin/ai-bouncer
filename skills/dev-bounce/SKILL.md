---
name: dev-bounce
description: 코드 수정, 기능 구현, 버그 수정, 리팩토링, 파일 변경 등 모든 개발 작업에 반드시 사용해야 하는 구조화된 워크플로우. 사용자가 코드 변경을 요청하면 항상 이 스킬을 먼저 호출할 것. 복잡도에 따라 SIMPLE/NORMAL 모드 자동 분기. 이 스킬을 건너뛰고 직접 Edit/Write하면 dev-bounce 워크플로우 없이 진행하는 것이다. 반드시 호출할 것.
---

# dev-bounce

복잡도에 따라 두 가지 모드로 분기:
- **SIMPLE**: Main Claude가 직접 계획·개발·검증 (팀/phase/step 없음)
- **NORMAL**: Main Claude 계획 수립 → 승인 → Dev Team → TDD 개발 → 검증

계획 승인 없이는 코드를 수정하지 않는다.

**주의: plan-gate.sh + bash-gate.sh(2-layer)는 아티팩트를 직접 검증합니다. Write/Edit뿐 아니라 Bash를 통한 파일 쓰기도 차단됩니다.**

---

## 컨텍스트 복원 (세션 재시작 시)

아래 Python 스크립트를 **반드시 그대로 실행**하여 활성/미완료 작업을 탐색한다.
git log, 수동 파일 탐색 등으로 대체하지 않는다.

```bash
python3 -c "
import json, os, glob

results = {'active': None, 'incomplete': []}

# 1) .active 파일 스캔
for state_file in sorted(glob.glob('.ai-bouncer-tasks/*/*/state.json'), reverse=True):
    task_dir = os.path.dirname(state_file)
    active_file = os.path.join(task_dir, '.active')
    if os.path.isfile(active_file):
        try:
            state = json.load(open(state_file))
        except:
            state = {}
        phase = state.get('workflow_phase', '')
        is_stale = (phase == 'done')
        results['active'] = {
            'task_dir': task_dir,
            'state_file': state_file,
            'phase': phase,
            'is_stale': is_stale,
            'active_file': active_file
        }
        break

# 1-b) state.json 없는 고아 .active 탐지
if not results['active']:
    for active_file in sorted(glob.glob('.ai-bouncer-tasks/*/*/.active'), reverse=True):
        task_dir = os.path.dirname(active_file)
        if not os.path.isfile(os.path.join(task_dir, 'state.json')):
            results['active'] = {
                'task_dir': task_dir,
                'state_file': None,
                'phase': '',
                'is_stale': True,
                'active_file': active_file
            }
            break

# 2) .active 없으면 미완료 작업 스캔
if not results['active']:
    for state_file in sorted(glob.glob('.ai-bouncer-tasks/*/*/state.json'), reverse=True):
        try:
            state = json.load(open(state_file))
        except: continue
        phase = state.get('workflow_phase', '')
        if phase in ('done', 'cancelled', ''): continue
        task_dir = os.path.dirname(state_file)
        task_name = os.path.basename(task_dir)
        date_dir = os.path.basename(os.path.dirname(task_dir))
        mode = state.get('mode', '?')
        dev_phase = state.get('current_dev_phase', 0)
        total_phases = len(state.get('dev_phases', {}))
        results['incomplete'].append({
            'label': f'{date_dir}/{task_name}',
            'phase': phase, 'mode': mode,
            'dev_phase': dev_phase, 'total_phases': total_phases,
            'task_dir': task_dir
        })

print(json.dumps(results, ensure_ascii=False))
"
```

### 결과 처리 (반드시 따를 것)

**Case A: `active`가 있음**

먼저 `is_stale` 확인:

**A-0: stale** (`is_stale == true` — `workflow_phase == "done"`인데 `.active` 존재, 불가능한 상태)
→ 자동 처리 (사용자에게 확인 없이):
  1. `.active` 파일 삭제: `rm -f {active_file}`
  2. 한 줄 안내: `⚠️ 잔여 잠금 파일 자동 정리: {task_dir} (done 상태였음)`
→ Case C로 진행 (새 작업 시작)

**A-1/A-2: stale 아님** (`workflow_phase != "done"`) — 사용자의 요청이 해당 active 작업과 관련된 것인지 판별한다.

- **A-1: 사용자 요청이 active 작업의 연장/이어하기인 경우**
  → 1. `.active` 파일 초기화 — **반드시 Write tool 사용** (doc-reminder hook이 session_id 즉시 기록):
       Write tool로 `{active_file}` 에 빈 파일 생성 (content: `""`)
  → 2. 해당 `state.json` 읽어 `workflow_phase` 확인 후 해당 Phase부터 재개.

  **A-1 특수 케이스: planning 단계인데 plan.md 없음**
  → compact 중에 세션이 잘려 plan.md가 저장되지 않은 상태.
  → 사용자에게 묻지 않고 자동 처리:
    1. `⚠️ 이전 계획 파일(plan.md)이 없습니다. Phase 1부터 다시 시작합니다.` 출력
    2. Phase 1 (계획 수립)부터 재시작

- **A-2: 사용자 요청이 active 작업과 무관한 새 작업인 경우**
  → **반드시 AskUserQuestion으로 사용자에게 확인.** 임의로 .active 해제/삭제 금지.
  ```
  기존 active 작업이 있습니다: [날짜/작업명] (workflow_phase)

  1. 기존 작업 유지하고 새 작업 시작 (병렬)
  2. 기존 작업 중단하고 새 작업 시작 (전환)
  3. 기존 작업 이어서 진행
  ```
  - 선택 1 → 기존 .active 그대로 두고, 새 TASK_DIR 생성 + 새 .active 생성. Phase 0 진행.
  - 선택 2 → 기존 task `state.json`의 `workflow_phase = "cancelled"` 업데이트 후 `.active` 삭제. 새 TASK_DIR 생성. Phase 0 진행.
  - 선택 3 → Case A-1과 동일하게 재개.

**Case B: `active`는 없고 `incomplete`가 1개 이상**
→ **반드시 AskUserQuestion으로 사용자에게 확인** 후 진행. 임의로 선택 금지.

표시 형식:
```
미완료 작업이 발견되었습니다:

1. [2026-03-12/ai-tycoon-reskin] — development (Phase 2/3, NORMAL)
2. [2026-03-10/auth-refactor] — verification (SIMPLE)

이어서 진행할 작업 번호를 선택하세요. 새 작업은 "새로":
```

사용자가 선택하면:
- **번호 선택**: 선택한 task_dir에 `.active` 파일을 Write tool로 빈 파일로 재생성 (doc-reminder hook이 session_id 즉시 기록) + `state.json`의 `workflow_phase`부터 재개.
  나머지 incomplete 태스크는 그대로 둔다 (다른 세션이 병렬 작업 중일 수 있음).
- **"새로" 선택**: cancel 없이 그냥 Case C 진행. 다른 incomplete 태스크는 건드리지 않는다.

**Case C: `active`도 `incomplete`도 없음**
→ 새 작업 시작. **즉시 Phase 0-A (TASK_DIR 초기화)** 진행.

---

### Phase 0-A: TASK_DIR 조기 초기화

⚠️ **/dev-bounce가 호출되면 인텐트 판별 전에 반드시 `.active`를 먼저 생성한다.**
이래야 hook이 이 세션의 Edit/Write/Bash를 감시할 수 있다. 인텐트 판별을 먼저 하면 Claude가 워크플로우를 건너뛰고 직접 수정할 수 있다.

TASK_DIR 초기화:

1. `TASK_NAME`: 요청에서 핵심 키워드 추출 (예: `user-auth`)
2. `docs_base`: `.ai-bouncer-tasks/YYYY-MM-DD/` (프로젝트 로컬)
3. `task_dir`: `{docs_base}/{TASK_NAME}`
4. `state.json` 생성 (Python/Bash):
5. `.active` 파일 생성 — **반드시 Write tool 사용** (doc-reminder hook이 session_id 즉시 기록, 빈 파일로 생성)

state.json 내용:

```json
{
  "workflow_phase": "planning",
  "mode": "pending",
  "planning": {"no_question_streak": 0},
  "plan_approved": false,
  "team_name": "",
  "current_dev_phase": 0,
  "current_step": 0,
  "dev_phases": {},
  "verification": {"rounds_passed": 0},
  "task_dir": ".ai-bouncer-tasks/YYYY-MM-DD/task-name",
  "active_file": ".ai-bouncer-tasks/YYYY-MM-DD/task-name/.active"
}
```

→ **즉시** Phase 0 (인텐트 판별) 진행

---

## Phase 0: 인텐트 판별

Main Claude가 직접 판별한다 (에이전트 스폰 없음):

- **일반응답** (질문, 설명 요청 등) → `.active` 삭제 + `state.json`의 `workflow_phase = "cancelled"` → 일반 응답 후 종료
- **내용불충분** (개발 의도는 있으나 구체적이지 않음) → AskUserQuestion으로 구체화 요청 후 Phase 0 재시도
  (예: "어떤 기능/버그를 개발·수정할지 구체적으로 알려주세요.")
  ⚠️ "개발 작업으로 처리할까요?" 같은 yes/no 확인 질문 절대 금지.
- **개발요청** → Phase 1 진행 (TASK_DIR은 이미 Phase 0-A에서 생성됨)

---

## Phase 1: 계획 수립 (SIMPLE/NORMAL 공통)

Main Claude가 직접 수행 (팀 스폰 없음):

⚠️ **Phase 1의 첫 번째 tool call은 반드시 EnterPlanMode이다.** 코드 탐색, 질문, 출력 등 어떤 행동보다 먼저 EnterPlanMode을 호출한다. plan mode 진입 전 다른 도구 호출 금지.

1. **EnterPlanMode 호출** (Phase 1 시작 = plan mode 진입, 예외 없음)
2. 관련 코드 탐색 (Read/Grep/Glob) — plan mode 안에서 수행
3. 필요시 사용자에게 AskUserQuestion 1~2회
4. plan mode plan 파일에 계획 작성 — **이것이 사용자에게 보이는 원본이자 최종 plan.md가 된다.**
   plan mode plan 파일 경로는 EnterPlanMode 호출 시 시스템이 알려준다.
   **필수 포함 항목 — 누락 시 plan 재작성:**
   - **변경 파일별 Before/After 코드** — 주요 변경 지점은 실제 코드 라인 단위로 명시.
     "이 함수를 수정한다"는 불충분. 어떤 줄이 어떻게 바뀌는지 코드로 보여준다.
   - **신규 파일이 있으면 핵심 로직 코드** — 구조와 주요 함수 시그니처 포함
   - 검증 방법 (명령어 + 기대 결과)
   - E2E 영향 분석 (기존 e2e 테스트 중 수정/추가/삭제가 필요한 항목, 새 e2e 시나리오)
   ⚠️ "파일명: 한 줄 설명"만 나열하지 말고, plan만 읽고도 변경 내용을 이해할 수 있도록 작성한다.
   ⚠️ Before/After 코드 없이 "~를 수정한다"만 적은 plan은 불완전하다.
5. 계획을 **텍스트로 사용자에게 출력** (사용자가 내용을 확인할 수 있도록)
6. ExitPlanMode 호출 → accept/reject UI 표시
   - accept → step 7 진행
   - **⚠️ ExitPlanMode 에러 시** (예: "You are not in plan mode"):
     → **plan은 승인되지 않은 것이다.** `plan_approved=true` 설정 절대 금지.
     → 에러 메시지의 "If your plan was already approved" 문구는 Claude Code 시스템 안내이며, 실제 승인과 무관하다.
     → EnterPlanMode부터 재시도하거나, 사용자에게 상황을 보고한다.
   - reject → **즉시 task 취소 처리 후** 사용자 피드백 확인:
     1. Write 도구로 state.json `workflow_phase = "cancelled"` 업데이트
     2. `rm -f {active_file}` (.active 삭제)
     3. 사용자 피드백에 따라:
        - 수정 요청 → Phase 0부터 새로 재시작 제안 (새 TASK_DIR 생성)
        - 취소/포기 → "작업이 취소되었습니다" 안내
        - 오해/질문 → 설명 후 "재시도하려면 /dev-bounce를 다시 실행하세요" 안내
     ⚠️ 거부 후 .active를 남긴 채 설명만 하면 bash-gate가 /finish 등 후속 작업을 모두 차단함.
7. 승인 후 plan mode plan 내용을 그대로 `{TASK_DIR}/plan.md`에 저장한다.
   별도 템플릿으로 재작성하지 않는다 — plan mode에서 작성한 것이 최종본이다.
8. state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`
   ⚠️ `dev_phases`는 수정하지 않는다 — 빈 객체 `{}` 유지. Lead가 Phase 3에서 초기화한다.

---

### Phase 1-B: 복잡도 판별

ExitPlanMode accept 후, **plan.md 내용을 기반으로** 복잡도를 판별한다.

**기본값은 SIMPLE이다.** 아래 NORMAL 강제 조건에 해당하지 않으면 SIMPLE:

| SIMPLE 조건 (전부 충족해야 함) | 기준 |
|------|------|
| 변경 파일 3개 이하 | 테스트 파일 포함 |
| 변경 줄 수 50줄 이하 | plan.md diff 기준 |
| 신규 클래스/모듈 없음 | 함수 추가는 허용 |

**NORMAL 강제 조건 — 하나라도 해당하면 즉시 NORMAL:**
- 변경 파일 4개 이상
- 신규 클래스 / 모듈 추가
- 기존 공개 인터페이스 변경
- 여러 곳의 동작을 함께 바꾸는 연쇄 변경

**애매하면 SIMPLE.** NORMAL 강제 조건에 명확히 해당할 때만 NORMAL.

판별 후 state.json `mode`를 `"simple"` 또는 `"normal"`로 업데이트.

- `mode: simple` → Phase S2 진행
- `mode: normal` → Phase 3 진행

---

## SIMPLE 모드

### Phase S2: 개발

#### TC 작성 (필수)

반드시 `{TASK_DIR}/tests.md`에 TC를 작성한다. TC 스킵 금지.

테이블 + 실행출력 형식으로 작성한다. **실행출력이 비어있으면 검증 미완료로 간주하여 Phase 진행 불가.**

```markdown
| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | <뭘 검증하는지> | <어떤 결과가 나와야 하는지 구체적으로> | ✅/❌/⬜ |
| TC-02 | ... | ... | ⬜ |

## 실행출력

검증 명령어를 실행한 결과를 그대로 붙여넣는다. 어떤 명령을 돌렸고, 실제로 뭐가 나왔는지 증거를 남긴다.

TC-01: <실행한 명령어> (Claude가 직접 실행해서 출력 확인)
→ <실제 출력 결과>

TC-02: <실행한 명령어>
→ <실제 출력 결과>
```

⬜는 미검증, ✅는 통과, ❌는 실패. 모든 TC가 ✅이고 실행출력이 채워져야 다음 단계 진행 가능.

**TC 검증 원칙: Claude가 직접 명령어를 실행해서 출력을 확인한다. "사용자가 앱 재시작 후 확인", "직접 열어서 확인" 등 수동 검증은 TC로 인정 안 됨.**

1. TC 먼저 작성 (검증 명령어 포함, 수동 검증 금지)
2. TC 기반으로 코드 개발
3. 개발 완료 후 TC 실행 → tests.md에 실행출력 + 판정(✅/❌) 기록
4. 모든 TC ✅일 때만 커밋 → Phase S3 진행

Main Claude가 직접 코드 수정 (phase/step 구조 없이 자유롭게).

> SIMPLE 모드에서는 `dev_phases`, `current_dev_phase`, `current_step`을 사용하지 않는다 (빈 객체/0 유지가 정상).
> hook은 SIMPLE 모드에서 이 필드를 검증하지 않는다.

#### S2 커밋 + 완료

개발 완료 + TC 전부 ✅ 후 커밋하고, **커밋 성공 즉시 같은 흐름에서 완료 처리**한다. 별도 Phase로 분리하지 않는다.

config.json에서 커밋 전략 확인 (로컬 우선 → 전역 fallback):

```bash
_BCFG=$(python3 -c "import os; d=['.claude/ai-bouncer/scripts','scripts']; g=os.path.expanduser('~/.claude/ai-bouncer/scripts'); print(next((p for p in [*d,g] if os.path.isfile(p+'/bouncer-config.sh')),''))")
COMMIT_STRATEGY=$(bash "$_BCFG/bouncer-config.sh" commit_strategy per-step)
COMMIT_SKILL=$(bash "$_BCFG/bouncer-config.sh" commit_skill false)
echo "$COMMIT_STRATEGY $COMMIT_SKILL"
```

| commit_strategy | SIMPLE 모드 커밋 시점 | commit_skill | 커밋 방법 |
|---|---|---|---|
| `per-step` | TC 전부 ✅ 직후 (SIMPLE에는 step이 없으므로 개발 완료 = 1 step) | `true` | `/commit` 스킬 호출 |
| `per-step` | TC 전부 ✅ 직후 | `false` | `git add` + `git commit` + `git push` |
| `per-phase` | TC 전부 ✅ 직후 (동일) | `true` | `/commit` 스킬 호출 |
| `per-phase` | TC 전부 ✅ 직후 (동일) | `false` | `git add` + `git commit` + `git push` |
| `none` | — | — | 커밋 스킵 (수동 관리) |

커밋 실패 시 다음 진행 금지 — 원인 해결 후 재시도.

커밋 성공 후 **반드시 이어서** (별도 Phase 아님):

1. 경량 검증: plan.md 대비 실제 변경 확인
   - `{TASK_DIR}/plan.md` 읽어 변경 예정 파일 파악
   - `git diff HEAD~1 --name-only`로 실제 변경 파일 확인
   - 계획됐으나 미변경 파일이 있으면 사용자에게 경고 표시 (차단은 안 함)
   - 간단한 체크리스트 출력:
     ```
     [경량 검증]
     ✅/⚠️ plan.md 대비 변경 확인: N/M 파일 일치
     (⚠️ 미변경: 파일명 — 의도된 것인지 확인 필요)
     ```
2. state.json `workflow_phase`를 `"done"`으로 업데이트  ← 먼저 (crash 시 done+active → 다음 세션에서 자동 정리)
3. active_file 삭제: `rm -f {active_file}`            ← 그 다음
4. 사용자에게 완료 보고

⚠️ 커밋과 완료 처리를 분리하면 done이 누락될 수 있다. 반드시 같은 응답 내에서 처리할 것.

---

## NORMAL 모드

### docs 디렉토리 구조

```
.ai-bouncer-tasks/YYYY-MM-DD/task-name/
├── .active                    # 세션 잠금
├── state.json                 # 워크플로우 상태
├── plan.md                    # 승인된 계획
├── phase-1-<이름>/            # 디렉토리 (flat file 금지)
│   ├── phase.md               # 필수: ## 목표, ## 범위, ## Steps
│   ├── step-1.md              # TC + 실행출력
│   └── step-2.md
├── phase-2-<이름>/
│   ├── phase.md
│   └── step-1.md
└── verifications/             # 반드시 복수형
    ├── round-1.md
    ├── round-2.md
    └── round-3.md
```

⚠️ `phase-N.md` (flat 파일) 생성 금지 — 반드시 `phase-N-<이름>/phase.md` 디렉토리 구조 사용.
⚠️ `verification/` (단수형) 생성 금지 — 반드시 `verifications/` (복수형) 사용.
hooks가 디렉토리 구조만 검증하므로 flat 파일은 무시된다.

### Phase 3: Dev Team 구성 + 개발

**agent_mode 확인** (config.json에서 읽기 — Phase 3/4 분기에 필요):

```bash
_BCFG=$(python3 -c "import os; d=['.claude/ai-bouncer/scripts','scripts']; g=os.path.expanduser('~/.claude/ai-bouncer/scripts'); print(next((p for p in [*d,g] if os.path.isfile(p+'/bouncer-config.sh')),''))")
bash "$_BCFG/bouncer-config.sh" agent_mode team
```

#### 3-1. Lead 에이전트 스폰

**agent_mode별 구성:**

| agent_mode | 동작 |
|---|---|
| `team` | TeamCreate로 Dev Team 생성 후 Lead 스폰. state.json `team_name` = TeamCreate 팀 이름 |
| `subagent` | Agent tool로 Lead 스폰. Lead가 Agent tool로 Dev/QA 스폰. state.json `team_name` = "" (빈 문자열) |
| `single` | Main Claude가 직접 phase 분해 + TDD 루프 수행. phase/step 구조는 유지 (hook 검증용). state.json `team_name` = "" |

**team 모드 (기본):**

> **TeamCreate 전 확인**: 이미 동일 이름 팀이 존재하면 반드시 TeamDelete 후 생성.
> "Already leading team" 에러 발생 시 → TeamDelete 후 재시도.

TeamCreate로 Dev Team 생성 후 TASK_DIR 전달하여 Lead 스폰.

Lead가 수행:
1. `{TASK_DIR}/plan.md` 읽기
2. 팀 규모 종합 판단 → `[TEAM:duo|team]` 출력
3. 고수준 계획 → 개발 Phase 분해 → `[DEV_PHASES:확정]`
4. state.json `dev_phases` 초기화 + `team_name = '<TeamCreate 팀 이름>'` 설정

> **중요: Lead에게 스폰 시 반드시 다음을 명시할 것:**
> "Lead는 오케스트레이터로서 코드 파일을 직접 Write/Edit/Bash로 수정하지 않는다.
> 코드 구현은 반드시 Dev 에이전트를 스폰하여 위임한다.
> git commit/push도 Lead가 직접 하지 않는다."

**subagent/single 모드**: Lead에게 agent_mode를 전달. team_name은 빈 문자열로 유지.

> **subagent/single 모드 state.json 업데이트 의무:**
>
> team 모드와 동일하게, 다음 시점에 state.json을 반드시 업데이트한다:
> - **Lead**: `dev_phases` 초기화 후 `current_dev_phase = 1`, `current_step = 1` 설정
> - **QA** (또는 Lead가 겸임 시 Lead): Step 테스트 통과 시 `current_step++`
> - **Lead**: Phase 완료 시 `current_dev_phase++`, `current_step = 1` 리셋
>
> plan-gate/bash-gate가 이 카운터와 아티팩트 파일을 모두 검증하므로, 카운터 미업데이트 시 다음 step 코드 수정이 차단된다.
> single 모드에서는 Main Claude가 직접 이 업데이트를 수행한다.

#### 3-2. 팀 구성 (Main Claude 담당)

> **⚠️ Lead가 아닌 Main Claude가 직접 스폰한다.**
> Lead로부터 `[TEAM:duo|team]` 응답을 받은 후, **Main Claude**가 Dev(+QA)를 스폰한다.
> Lead가 Agent tool로 Dev를 스폰하는 것은 구조 위반이다.

| Lead 출력 | Main Claude 액션 |
|---|---|
| `[TEAM:duo]` | Dev 에이전트 1명 스폰. QA 역할(TC 작성·검증)은 **Main Claude**가 직접 수행. |
| `[TEAM:team]` | Dev + QA 에이전트 각 1명 스폰 |

> NORMAL 모드는 이미 복잡한 작업으로 판별된 상태. 최소 duo부터 시작한다.
> duo 모드에서 Lead는 TC를 직접 작성하지 않는다. Main Claude가 QA 역할을 담당한다.

#### 3-3. TDD 개발 루프 (Phase/Step 반복)

각 개발 Phase의 각 Step마다:

```
5-1. QA: .ai-bouncer-tasks/<task>/phase-N-<이름>/step-M.md에 TC 먼저 작성
     → [STEP:N:테스트정의완료] 출력

5-2. Dev: TC 통과할 최소 코드 구현
          .ai-bouncer-tasks/<task>/phase-N-<이름>/step-M.md 구현 내용 업데이트
     → [STEP:N:개발완료]
       빌드 명령: <명령어>
       결과: ✅ 성공

5-3. QA: 테스트 실행
     → [STEP:N:테스트통과]
       명령어: <명령어>
       결과: N/N 통과
     → step-M.md TC 테이블 "실제 결과" 컬럼에 ✅ 기록
     → step-M.md에 "## 실행 결과" 섹션 추가하여 실제 명령어 출력 붙여넣기 (필수)
     → state.json current_step++
     ⚠️ plan-gate가 이전 step의 실행출력 존재를 검증함. 없으면 다음 step 차단.

     실패 시 → Dev에 반려 → 5-2 반복
```

> **phase.md 필수 섹션**: `## 목표`, `## 범위`, `## Steps` — plan-gate가 검증하며 누락 시 코드 수정 차단.

#### 3-4. Step/Phase 완료 시 커밋

`.claude/ai-bouncer/config.json`에서 커밋 전략 확인 (프로젝트 로컬 경로):

```bash
_BCFG=$(python3 -c "import os; d=['.claude/ai-bouncer/scripts','scripts']; g=os.path.expanduser('~/.claude/ai-bouncer/scripts'); print(next((p for p in [*d,g] if os.path.isfile(p+'/bouncer-config.sh')),''))")
COMMIT_STRATEGY=$(bash "$_BCFG/bouncer-config.sh" commit_strategy per-step)
COMMIT_SKILL=$(bash "$_BCFG/bouncer-config.sh" commit_skill false)
echo "$COMMIT_STRATEGY $COMMIT_SKILL"
```

| commit_strategy | 커밋 시점 | commit_skill | 커밋 방법 |
|---|---|---|---|
| `per-step` | `[STEP:N:테스트통과]` 직후 | `true` | `/commit` 스킬 호출 |
| `per-step` | `[STEP:N:테스트통과]` 직후 | `false` | `git add` + `git commit` + `git push` |
| `per-phase` | 개발 Phase 마지막 Step 통과 후 | `true` | `/commit` 스킬 호출 |
| `per-phase` | 개발 Phase 마지막 Step 통과 후 | `false` | `git add` + `git commit` + `git push` |
| `none` | — | — | 커밋 스킵 (수동 관리) |

커밋 실패 시 다음 진행 금지 — 원인 해결 후 재시도. (per-step: 다음 Step 차단, per-phase: 다음 Phase 차단)

#### 3-5. 블로킹 에스컬레이션

Dev/QA가 구현 불가 또는 기획 질문이 생긴 경우:

```
[STEP:N:블로킹:기술불가] 또는 [STEP:N:블로킹:기획질문]
```

처리:
- `기술불가`: 사용자에게 보고, 범위 변경 필요하면 Phase 1 재시작
- `기획질문`: state.json `workflow_phase = "planning"` 리셋 → Phase 1 재시작

#### 3-6. Phase 완료 처리 (Main Claude 필수 확인)

Lead가 `[PHASE:N:완료]` 또는 `[ALL_STEPS:완료]`를 출력하면, **Main Claude가 반드시 다음을 확인**:

```bash
# state.json에서 남은 Phase 확인
python3 -c "
import json
state = json.load(open('{TASK_DIR}/state.json'))
current = state.get('current_dev_phase', 0)
total = len(state.get('dev_phases', {}))
print(f'current={current} total={total}')
if current < total:
    print(f'NEXT_PHASE={current + 1}')
else:
    print('ALL_DONE')
"
```

**결과에 따라 분기 (반드시 따를 것):**

- `NEXT_PHASE=N` → **Phase 4로 넘어가지 않는다.** Lead에게 "Phase N 개발을 시작하라"고 지시.
  state.json `current_dev_phase`를 N으로 업데이트.
- `ALL_DONE` → 모든 Phase 완료. Phase 4 (검증 루프) 진행.

> **주의**: Lead가 `[ALL_STEPS:완료]`를 출력해도 state.json의 dev_phases에 남은 Phase가 있으면
> **절대 Phase 4로 넘어가지 않는다.** 남은 Phase를 먼저 모두 완료해야 한다.
> Lead가 잘못 판단할 수 있으므로 Main Claude가 직접 dev_phases 개수를 확인한다.

---

### Phase 4: 검증

Phase 4 시작 전 state.json `workflow_phase`를 `"verification"`으로 업데이트.
(completion-gate.sh가 verification 상태에서 검증 통과 전 응답 종료를 차단)

**agent_mode별 구성:**

| agent_mode | 동작 |
|---|---|
| `team` | verifier 에이전트 스폰 (기본) |
| `subagent` | Agent tool로 verifier 스폰 |
| `single` | Main Claude가 직접 검증 수행 |

1. verifier 에이전트 스폰 (TASK_DIR 전달)
2. verifier가 통합 검증 실행 (기능 충실도 + 코드 품질 + 테스트)

3. `[VERIFICATION:1:실패:PHASE-P-STEP-M]` 수신 시:
   - verifier가 자동으로: workflow_phase → "development", 실패 step ✅→❌, failure_count +1
   - **plan-gate가 verification 재진입을 자동 차단** (step에 ✅ 없으므로)
   - Main Claude가 Dev에게 실패한 Step 재작업 지시
   - Dev가 수정 완료 → step.md에 ✅ 복구
   - Main Claude가 workflow_phase → "verification" 재설정
   - verifier에게 "재검증" 요청

4. `[VERIFICATION:ESCALATION]` 수신 시 (failure_count >= 3):
   - AskUserQuestion으로 사용자에게 보고
   - 사용자 승인 없이 재시도 금지

5. `[DONE]` 수신 (3라운드 연속 통과, verifications/round-1~3.md):
   - verifier + 전체 팀 shutdown
   - state.json `workflow_phase`를 `"done"`으로 업데이트  ← 먼저 (crash 시 done+active → 다음 세션에서 자동 정리)
   - active_file 삭제: `rm -f {active_file}`             ← 그 다음
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
- 검증 미완료(NORMAL: round-1.md 통과 필요) 상태에서 응답 종료 → completion-gate.sh가 차단
- 커밋: 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md`
- 완료 후 task_dir 삭제 금지 — active_file(`.ai-bouncer-tasks/YYYY-MM-DD/<task>/.active`)만 삭제한다
- 세션 격리: `.active` 파일은 `.ai-bouncer-tasks/YYYY-MM-DD/<task>/.active`에 위치하며 session_id를 저장. hook이 자동으로 claim한다.
- docs 구조: `.ai-bouncer-tasks/YYYY-MM-DD/task-name/` — 날짜별로 태스크 문서를 구조화
- config.json 경로: `.claude/ai-bouncer/config.json` (프로젝트 로컬) → 없으면 `~/.claude/ai-bouncer/config.json` (전역) fallback
- `enforcement_mode=prompt-only`일 때 hook이 없으므로 프롬프트 규칙만으로 워크플로우를 준수해야 한다. 차단이 아닌 가이드 역할.
- `agent_mode`에 따라 Phase 3/4의 에이전트 스폰 방식이 달라진다. config.json에서 확인 후 분기. Phase 1(계획 수립)은 항상 Main Claude가 직접 수행.
