---
name: dev-bounce
description: 코드 수정, 기능 구현, 버그 수정, 리팩토링, 파일 변경 등 모든 개발 작업에 반드시 사용해야 하는 구조화된 워크플로우. 사용자가 코드 변경을 요청하면 항상 이 스킬을 먼저 호출할 것. 모든 작업을 phase/step 구조로 처리하는 통일 워크플로우. 이 스킬을 건너뛰고 직접 Edit/Write하면 dev-bounce 워크플로우 없이 진행하는 것이다. 반드시 호출할 것.
---

# dev-bounce

> ⛔ **이 스킬이 로드된 즉시 — 인자 해석·파일 탐색·Edit/Write 모두 금지.**
> **가장 먼저 아래 "Step 1: 컨텍스트 복원 스크립트"를 실행한다. 예외 없음.**

모든 개발 작업을 **단일 phase/step 구조**로 처리한다:
- Main Claude 계획 수립 → 승인 → Dev Team → TDD 개발 (phase/step) → e2e 검증

계획 승인 없이는 코드를 수정하지 않는다.

**주의: plan-gate.sh + bash-gate.sh(2-layer)는 아티팩트를 직접 검증합니다. Write/Edit뿐 아니라 Bash를 통한 파일 쓰기도 차단됩니다.**

---

## Step 1: 컨텍스트 복원 (신규·재시작 모두 항상 실행)

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
        is_stale = (phase in ('done', 'cancelled'))
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
        dev_phase = state.get('current_dev_phase', 0)
        total_phases = len(state.get('dev_phases', {}))
        results['incomplete'].append({
            'label': f'{date_dir}/{task_name}',
            'phase': phase,
            'dev_phase': dev_phase, 'total_phases': total_phases,
            'task_dir': task_dir
        })

print(json.dumps(results, ensure_ascii=False))
"
```

### 결과 처리 (반드시 따를 것)

**Case A: `active`가 있음**

먼저 `is_stale` 확인:

**A-0: stale** (`is_stale == true` — `workflow_phase == "done"` 또는 `"cancelled"`인데 `.active` 존재)
→ 자동 처리 (사용자에게 확인 없이):
  1. `.active` 파일 삭제: `rm -f {active_file}`
  2. 한 줄 안내: `⚠️ 잔여 잠금 파일 자동 정리: {task_dir} (done 상태였음)`
→ Case C로 진행 (새 작업 시작)

**A-1/A-2: stale 아님** (`workflow_phase != "done"`) — 사용자의 요청이 해당 active 작업과 관련된 것인지 판별한다.

- **A-1: 사용자 요청이 active 작업의 연장/이어하기인 경우**
  → 1. `.active` 파일 재클레임:
       `bash {BOUNCER_SCRIPTS}/claim-active.sh "{active_file}"`
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

1. [2026-03-12/ai-tycoon-reskin] — development (Phase 2/3)
2. [2026-03-10/auth-refactor] — verification

이어서 진행할 작업 번호를 선택하세요. 새 작업은 "새로":
```

사용자가 선택하면:
- **번호 선택**: 선택한 task_dir에 `.active` 재클레임: `bash {BOUNCER_SCRIPTS}/claim-active.sh "{active_file}"` + `state.json`의 `workflow_phase`부터 재개.
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
4. `.active` 파일 생성 — `bash {BOUNCER_SCRIPTS}/claim-active.sh "{task_dir}/.active"` (session_id 즉시 기록)
5. `state.json` 생성 (Python/Bash):

state.json 내용:

```json
{
  "workflow_phase": "planning",
  "plan_approved": false,
  "current_dev_phase": 0,
  "current_step": 0,
  "dev_phases": {},
  "verification": {"e2e_passed": false},
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

## Phase 1: 계획 수립

Main Claude가 직접 수행 (팀 스폰 없음):

⚠️ **Phase 1의 첫 번째 tool call은 반드시 EnterPlanMode이다.** 코드 탐색, 질문, 출력 등 어떤 행동보다 먼저 EnterPlanMode을 호출한다. plan mode 진입 전 다른 도구 호출 금지.

1. **EnterPlanMode 호출** (Phase 1 시작 = plan mode 진입, 예외 없음)
2. 관련 코드 탐색 (Read/Grep/Glob) — plan mode 안에서 수행
3. 필요시 사용자에게 AskUserQuestion 1~2회
4. plan mode plan 파일에 계획 작성 — **이것이 사용자에게 보이는 원본이자 최종 plan.md가 된다.**
   plan mode plan 파일 경로는 EnterPlanMode 호출 시 시스템이 알려준다. **이 경로를 PLAN_FILE로 기억한다.**
   **필수 포함 항목 — 누락 시 plan 재작성:**
   - **변경 파일별 Before/After 코드** — 주요 변경 지점은 실제 코드 라인 단위로 명시.
     "이 함수를 수정한다"는 불충분. 어떤 줄이 어떻게 바뀌는지 코드로 보여준다.
   - **신규 파일이 있으면 핵심 로직 코드** — 구조와 주요 함수 시그니처 포함
   - 검증 방법 (명령어 + 기대 결과)
   - E2E 영향 분석 (기존 e2e 테스트 중 수정/추가/삭제가 필요한 항목, 새 e2e 시나리오)
   - **개발 Phase 계획** (필수 — Phase 3에서 Main Claude가 이걸 기반으로 phase/step 문서 생성):
     ```markdown
     ## 개발 Phase 계획
     
     ### Phase 1: <이름>
     **목표**: ...
     - Step 1: <제목> — <완료 기준>
     - Step 2: <제목> — <완료 기준>
     
     ### Phase 2: <이름>
     **목표**: ...
     - Step 1: <제목> — <완료 기준>
     ```
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
7. **⚠️ CRITICAL — state.json 업데이트 전 반드시 먼저 실행**: plan mode plan 파일을 `{TASK_DIR}/plan.md`로 복사한다.
   - `PLAN_FILE`: EnterPlanMode가 알려준 plan 파일 경로 (예: `~/.claude/plans/{slug}.md`)
   - 복사: `cp "$PLAN_FILE" "{TASK_DIR}/plan.md"` — 이 단계를 건너뛰면 gate가 모든 후속 작업을 차단함.
   - 별도 템플릿으로 재작성하지 않는다 — plan mode에서 작성한 것이 최종본이다.
8. state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`
   ⚠️ step 7 cp 완료 확인 후에만 실행.
   ⚠️ `dev_phases`는 수정하지 않는다 — 빈 객체 `{}` 유지. Phase 3에서 초기화한다.
   ⚠️ `resolved_agent_mode`도 설정하지 않는다 — Phase 3에서 문서 생성 후 결정한다.

---

### docs 디렉토리 구조

```
.ai-bouncer-tasks/YYYY-MM-DD/task-name/
├── .active                    # 세션 잠금
├── state.json                 # 워크플로우 상태
├── plan.md                    # 승인된 계획
├── phase-1-<이름>/            # 디렉토리 (flat file 금지)
│   ├── phase.md               # 필수: ## 목표, ## Steps
│   ├── step-1.md              # TC + 실행출력
│   └── step-2.md
├── phase-2-<이름>/
│   ├── phase.md
│   └── step-1.md
└── verifications/             # 반드시 복수형
    ├── e2e-tests/             # e2e 스크립트 디렉토리
    └── e2e-result.md          # critical-reviewer 검증 결과
```

⚠️ `phase-N.md` (flat 파일) 생성 금지 — 반드시 `phase-N-<이름>/phase.md` 디렉토리 구조 사용.
⚠️ `verification/` (단수형) 생성 금지 — 반드시 `verifications/` (복수형) 사용.
hooks가 디렉토리 구조만 검증하므로 flat 파일은 무시된다.

### Phase 3: Dev Team 구성 + 개발

**agent_mode 확인** (state.json에서 읽기 — Phase 3에서 문서 생성 후 결정됨):

```bash
python3 -c "import json; s=json.load(open('{TASK_DIR}/state.json')); print(s.get('resolved_agent_mode','team'))"
```

> Phase 4도 동일하게 state.json의 `resolved_agent_mode` 값을 사용한다.

#### 3-1. 문서 생성 (Main Claude 직접 수행)

Main Claude가 수행:
1. `{TASK_DIR}/plan.md` 읽기
2. 고수준 계획 → 개발 Phase 분해 → `[DEV_PHASES:확정]` 출력
3. state.json `dev_phases` 초기화 (각 phase에 `team_name: ""` 포함)
4. **모든 phase/step 문서 골격 일괄 생성 (순서 엄수)**

   > ⚠️ **개발 시작 전 필수**: 문서 생성이 완료되기 전까지 Dev/QA 스폰 절대 금지.
   > Phase 1 docs가 완료됐다고 개발을 시작하지 않는다.
   > **모든 Phase의 모든 Step 문서**를 전부 만든 후에야 resolved_agent_mode를 결정한다.

   Phase N마다 아래 순서를 반드시 지킨다:

   ```
   Phase 1:
     → phase-1-<이름>/ 디렉토리 생성
     → phase-1-<이름>/phase.md 작성 (## 목표, ## 기술 접근, ## Steps 포함)
     → phase-1-<이름>/step-1.md stub 작성  ← 반드시 phase.md 직후
     → phase-1-<이름>/step-2.md stub 작성  ← step 수만큼 반복
   Phase 2:
     → phase-2-<이름>/ 디렉토리 생성
     → phase-2-<이름>/phase.md 작성
     → phase-2-<이름>/step-1.md stub 작성
     ... (모든 Phase 완료까지)
   ```

   **[phase.md 작성 기준]** — 반드시 아래 3섹션 모두 포함:

   ```markdown
   ## 목표
   plan.md 해당 Phase 목표 발췌 (1~2문장)

   ## 기술 접근
   이 Phase에서 수정하는 각 파일에 대해 한 줄씩:
   - `파일명`: (현재 핵심 로직/구조) → (변경 후 핵심 로직/구조)

   예:
   - `components/ChannelFilter.tsx`: border-l-3 고정 선택 표시 → OKLCH hue 동적 배경색 + checkbox
   - `lib/constants.ts`: 없음 → CHANNEL_HUE_MAP, getChannelHue/channelColor/channelTint/channelDeep 추가

   ⚠️ 금지: "수정한다", "추가한다"만 쓰는 것 — 무엇이 어떻게 바뀌는지 반드시 명시

   ## Steps
   - Step N: 제목 — 완료 기준 (어떤 명령/상태면 완료인지 명시)
   ```

   **[step.md stub 작성 기준]** — ## 구현 목표를 직접 채운다. TC는 비워둔다 (QA가 채움):

   ```markdown
   ## 구현 목표
   - 변경 대상: `파일명`
   - 핵심 변경: (plan.md Step N Before/After에서 발췌, 2~5줄)
     예: "RatingChip 컴포넌트 신규 — rating 값에 따라 bg/fg/flame 동적 설정"
     예: "img 컨테이너 h-16 w-24 landscape → h-[76px] w-[76px] 정사각형으로 변경"
     예: "isSelected 시 style.background=channelTint(hue), borderColor=channelColor(hue) 적용"
   - 참고: plan.md ## Phase N / Step M

   ## 테스트 기준

   | TC-ID | 유형 | 시나리오 | 기대 결과 | 실제 결과 |
   |-------|------|----------|-----------|-----------|
   | TC-1  |      |          |           |           |
   ```

   ⚠️ ## 구현 목표가 "변경 대상: 파일명" 단 1줄이면 불충분 — plan.md Before/After 핵심을 반드시 발췌

5. **resolved_agent_mode 결정 후 state.json에 저장:**

   **먼저 config.json에서 agent_mode를 읽는다** (항상):
   ```bash
   _BCFG=$(python3 -c "import os; d=['.claude/ai-bouncer/scripts','scripts']; g=os.path.expanduser('~/.claude/ai-bouncer/scripts'); print(next((p for p in [*d,g] if os.path.isfile(p+'/bouncer-config.sh')),''))")
   CONFIG_MODE=$(bash "$_BCFG/bouncer-config.sh" agent_mode team)
   ```

   그 다음 PHASE_COUNT 기준으로 최종 결정:
   - PHASE_COUNT ≤ 3 → `resolved_agent_mode = "single"` (Phase 수 기준 자동 override)
     ⚠️ **반드시 아래 메시지를 출력한다:**
     - CONFIG_MODE가 "single"이면: `"📊 Phase {N}개 → single 모드 자동 선택"`
     - CONFIG_MODE가 다른 값이면: `"📊 Phase {N}개 → single 모드 자동 선택 (config: {CONFIG_MODE} → Phase ≤ 3이므로 override)"`
   - PHASE_COUNT > 3 → CONFIG_MODE 값 그대로 사용
     ⚠️ **반드시 아래 메시지를 출력한다:**
     `"📊 Phase {N}개 → {CONFIG_MODE} 모드 사용 (config.json)"`

   ```bash
   python3 -c "
   import json
   s = json.load(open('{TASK_DIR}/state.json'))
   s['resolved_agent_mode'] = '{결정된 값}'
   json.dump(s, open('{TASK_DIR}/state.json','w'), ensure_ascii=False, indent=2)
   "
   ```

문서 생성 + 모드 결정 완료 → 3-2 팀 구성 진행

**subagent 모드**: 문서 생성 완료 후 Main Claude가 Agent tool로 Dev + QA를 각 1명씩 스폰한다. dev_phases[N].team_name은 빈 문자열로 유지.

> **state.json 업데이트 의무:**
>
> team 모드와 동일하게, 다음 시점에 state.json을 반드시 업데이트한다:
> - **Main Claude**: 문서 생성 완료 후 `dev_phases` 초기화, `current_dev_phase = 1`, `current_step = 1` 설정
> - **QA**: Step 테스트 통과 시 `current_step++`
> - **Main Claude**: Phase 완료 시 `current_dev_phase++`, `current_step = 1` 리셋
>
> plan-gate/bash-gate가 이 카운터와 아티팩트 파일을 모두 검증하므로, 카운터 미업데이트 시 다음 step 코드 수정이 차단된다.
> single 모드에서는 Main Claude가 직접 이 업데이트를 수행한다.

#### 3-2. 팀 구성 (Main Claude 담당)

**team 모드:**
> 문서 생성 완료 후 Main Claude가 Dev + QA를 각 1명씩 스폰한다.
>
> **⚠️ 반드시 `team_name`과 `name` 파라미터 포함 (단일 응답 병렬 발송):**
> ```
> Agent(team_name="{TASK_NAME}", name="dev", prompt=Dev스폰프롬프트)  ┐ 병렬
> Agent(team_name="{TASK_NAME}", name="qa",  prompt=QA스폰프롬프트)   ┘ 병렬
> ```
> `team_name` 없이 Agent()만 쓰면 팀 미등록 → hook 전면 차단.

**subagent 모드:**
> 문서 생성 완료 후 **Main Claude가** Agent tool로 Dev + QA를 각 1명씩 스폰한다.

항상 Dev + QA 에이전트 각 1명 스폰. QA 없이 Dev만 스폰하는 것은 금지.

> **⚠️ 병렬 스폰 필수**: Dev + QA Agent() 호출을 **단일 응답에서 동시에 발송**한다.
> QA Agent() 호출 후 응답을 기다린 뒤 Dev Agent() 호출하는 것은 순차 실행이므로 금지.
> 두 Agent() 호출을 같은 응답의 tool call 블록에 함께 포함해야 실제 병렬 실행된다.

> **에이전트 수명 — 병렬성 기반 스폰 전략:**
>
> Main Claude가 팀 스폰 전에 각 Phase의 병렬 실행 가능 여부를 판단하고 state.json에 기록한다.
>
> **병렬성 판단 기준 (Main Claude가 plan.md Before/After를 읽고 직접 판단):**
> - Phase B가 Phase A의 결과물(함수, 타입, 컴포넌트)을 사용 → 순차
> - Phase A의 변경이 Phase B 구현의 정확성에 영향 → 순차
> - 두 Phase가 서로 완전히 독립적으로 구현 가능 → 병렬
> (파일 겹침은 힌트일 뿐, 최종 판단은 작업 간 영향 여부)
>
> Main Claude가 state.json dev_phases에 `depends_on` 필드로 기록:
> ```json
> "dev_phases": {
>   "1": {"name": "...", "steps": {...}, "depends_on": [], "team_name": ""},
>   "2": {"name": "...", "steps": {...}, "depends_on": [], "team_name": ""},
>   "3": {"name": "...", "steps": {...}, "depends_on": [1, 2], "team_name": ""}
> }
> ```
> `depends_on: []` = 의존 없음, 즉시 실행 가능.
> `depends_on: [1, 2]` = Phase 1, 2가 모두 완료된 후 실행.
>
> **병렬 Phase가 있는 경우 (depends_on: []인 Phase N, M이 여럿):**
>
> 1단계 — 각 Phase마다 팀 생성 [단일 응답 병렬 발송]:
> ```
> TeamCreate("{TASK_NAME}-p{N}")  ┐ 병렬
> TeamCreate("{TASK_NAME}-p{M}")  ┘ 병렬
> → state.json dev_phases[N].team_name = "{TASK_NAME}-p{N}" 업데이트 (Write 도구)
> → state.json dev_phases[M].team_name = "{TASK_NAME}-p{M}" 업데이트 (Write 도구)
> ```
>
> 2단계 — 각 Phase의 Dev+QA 스폰 [단일 응답 병렬 발송]:
> ```
> Agent(team_name="{TASK_NAME}-p{N}", name="dev", ...)  ┐
> Agent(team_name="{TASK_NAME}-p{N}", name="qa", ...)   ┤ 병렬
> Agent(team_name="{TASK_NAME}-p{M}", name="dev", ...)  ┤
> Agent(team_name="{TASK_NAME}-p{M}", name="qa", ...)   ┘
> ```
> 각 Phase의 Dev+QA는 해당 Phase의 team_name으로 스폰. 각 쌍 내 Step 간에는 SendMessage로 재활용.
>
> **순차 Phases (Phase N+1이 Phase N에 의존하는 경우):**
> 최초 진입 Phase에서만 TeamCreate + Dev+QA 스폰.
> 이후 의존 Phase들은 같은 팀·같은 에이전트를 SendMessage로 재활용.
> ```
> TeamCreate("{TASK_NAME}-seq")
> → dev_phases["1"].team_name = "{TASK_NAME}-seq" 업데이트
> → dev_phases["2"].team_name = "{TASK_NAME}-seq" 업데이트  ← 의존 Phase도 동일 팀 이름으로 미리 채움
> → Dev+QA 최초 1회 스폰 (team_name="{TASK_NAME}-seq")
> → Phase N+1 시작 시: SendMessage 재활용 (재스폰 금지)
> ```
>
> **혼합 전략 (병렬 Phase 이후 의존 Phase가 있는 경우):**
> ```
> Phase 1 (depends_on: [])     → TeamCreate("{TASK_NAME}-p1") → dev_phases["1"].team_name = "{TASK_NAME}-p1"
> Phase 2 (depends_on: [])     → TeamCreate("{TASK_NAME}-p2") → dev_phases["2"].team_name = "{TASK_NAME}-p2"
> Phase 3 (depends_on: [1, 2]) → 1, 2 완료 후 TeamCreate("{TASK_NAME}-p3") → dev_phases["3"].team_name = "{TASK_NAME}-p3"
> ```
> Phase 3이 새 팀을 만드는 이유: Phase 1/2의 Dev+QA는 각자의 팀 소속이라
> SendMessage로 재활용 불가 → 새 Dev+QA 스폰 필요 → 새 팀도 필요.
>
> ⚠️ 같은 팀 내에서 Phase가 바뀐 경우(순차) "새 Phase가 시작됐다"는 이유만으로 에이전트를 재스폰하지 않는다.
> ⚠️ 같은 팀 내 Phase N 완료 후 Phase N+1 시작 시 같은 에이전트에 SendMessage한다.

> **Dev/QA 스폰 시 반드시 프롬프트에 포함:**
> `IS_DELEGATED_AGENT=true`
> 이 값이 있어야 ai-bouncer hook이 에이전트의 파일 수정을 허용한다.

## QA 스폰 프롬프트

> **QA 스폰 프롬프트 (Main Claude가 아래 내용을 그대로 QA에게 전달한다):**
>
> 당신은 소프트웨어 QA·테스트 엔지니어링 분야 20년 경력의 QA 리드입니다.
> 현재 Phase: {PHASE_N} — {PHASE_NAME}
> TASK_DIR: {TASK_DIR}
>
> **[역할]**
> - step.md의 ## 구현 목표를 읽고 TC를 작성합니다 (Dev 구현 전)
> - Dev 구현 완료 후 TC를 실행하고 결과를 기록합니다
> ⚠️ 절대로 사용자에게 질문하지 않는다. 모호한 부분은 step.md → plan.md → TC 순으로 참조해 자체 판단한다. 해결 불가 시 [STEP:N:블로킹:기획질문]으로 보고한다.
> ⚠️ 모든 파일 Read/Write/Edit/Bash 도구 사용이 사전 허가되어 있다. 권한 확인 없이 즉시 실행한다.
>
> **[TC 유형]** — TC마다 아래 유형 중 하나를 반드시 지정합니다:
>
> | 유형 | 설명 | 예시 시나리오 |
> |------|------|---------------|
> | `happy` | 정상 흐름 확인 — 기본 동작이 의도대로 작동 | "컴포넌트가 props를 받아 정상 렌더링됨" |
> | `negative` | 오류·예외·빈 상태·null 처리 — 비정상 입력/상태에서 안전하게 동작 | "thumbnailUrl=null 시 Placeholder 렌더링" |
> | `boundary` | 경계값 — 0개, 1개, 최대값, 최솟값 등 경계 조건 | "채널 0개일 때 빈 목록 렌더링" |
> | `e2e` | 실제 사용자 흐름/UI 인터랙션 — 클릭·입력·상태변화의 런타임 결과 | "채널 클릭 시 hue border 색상 변경됨" |
> | `integration` | 컴포넌트 간 상호작용 — props drilling, context, 이벤트 전파 | "카드 클릭 시 부모 onClick 호출되고 isSelected 전환" |
> | `regression` | 기존 동작 깨지지 않음 — 변경 전 동작이 여전히 작동 | "기존 channelName 표시 위치 유지됨" |
> | `type-check` | 정적 타입·빌드·컴파일 오류 없음 | "npx tsc --noEmit 오류 0건" |
>
> ⚠️ TC 유형은 구현 목표의 성격에 맞게 균형 있게 선택합니다.
> ⚠️ e2e TC는 가능하면 포함을 권장합니다. 단, 순수 빌드 step에서는 불필요할 수 있습니다.
> ⚠️ type-check TC만으로 TC를 채우는 것은 품질 미달입니다.
>
> **[e2e TC 작성 요령]** — 실제 런타임/브라우저에서 발생하는 동작을 기술합니다:
>
> ✅ 올바른 e2e TC:
> - 시나리오: "isSelected=true 전달 시 background가 channelTint(hue)로 변경됨"
>   기대결과: "style.background === oklch(0.96 0.02 {hue}) 값으로 설정"
> - 시나리오: "RestaurantCard 클릭 시 배경색·border 변경됨"
>   기대결과: "style.background=#FFFAF1, style.borderColor=oklch(0.68 0.18 28) 적용"
>
> ✗ e2e가 아닌 것:
> - "파일이 존재한다" → happy
> - "import 구문이 constants에서 참조됨" → happy
> - "tsc 오류 없음" → type-check
>
> **[TC 충실도 기준]**
> - 시나리오: 5자 이상, 입력 조건·상태 구체적으로 명시
> - 기대결과: 5자 이상, 출력·상태·값 구체적으로 명시
> - ✗ "동작함", "성공함" 단독 사용 금지
>
> **[테스트 실행 후 기록]**
> - TC 테이블 실제결과 컬럼 ✅/❌ 업데이트
> - step.md에 ## 실행출력 섹션 추가 (실제 명령어 출력 최소 2줄)
> - state.json current_step++ 업데이트
> - [STEP:N:테스트통과] 출력

> **에이전트 수명**: QA + Dev는 Phase 시작 시 **한 번만 스폰**한다.
> Step이 바뀌어도 새로 스폰하지 않는다 — **SendMessage로 재활용**한다.
> Phase가 끝나면 에이전트를 종료하고 다음 Phase에서 새로 스폰한다.

## Dev 스폰 프롬프트

> **Dev 스폰 프롬프트 (Main Claude가 아래 내용을 그대로 Dev에게 전달한다):**
>
> 당신은 소프트웨어 개발 분야 20년 경력의 시니어 엔지니어입니다.
> 현재 Phase: {PHASE_N} — {PHASE_NAME}
> TASK_DIR: {TASK_DIR}
>
> **[역할]**
> step.md의 ## 구현 목표와 TC를 읽고 최소 코드로 구현합니다.
> plan.md의 Before/After 코드를 기준으로 정확히 구현합니다.
> ⚠️ 절대로 사용자에게 질문하지 않는다. 모호한 부분은 ## 구현 목표 → plan.md → TC 순으로 참조해 자체 판단한다. 해결 불가 시 [STEP:N:블로킹:기술불가]로 보고한다.
> ⚠️ 모든 파일 Read/Write/Edit/Bash 도구 사용이 사전 허가되어 있다. 권한 확인 없이 즉시 실행한다.
>
> **[구현 시작 전 반드시 수행]**
> 1. step.md의 ## 구현 목표를 읽어 변경 대상 파일과 핵심 변경을 파악
> 2. plan.md의 해당 Phase/Step 섹션에서 Before/After 코드를 확인
> 3. step.md의 TC 목록을 읽어 기대결과 파악 (QA와 병렬 진행 중이므로 TC가 아직 비어있을 수 있음 — 그 경우 구현 목표와 plan.md 기준으로 구현)
> 4. 변경 대상 파일의 현재 코드를 Read 도구로 읽어 기존 패턴 파악
>
> **[구현 기준]**
> 1. **plan.md After 코드가 정답** — Before/After가 명시되어 있으면 After를 그대로 구현. 임의로 변형하지 않는다
> 2. **TC 기반 구현** — TC의 기대결과를 하나씩 체크하며 구현. TC에 없는 동작은 추가하지 않는다
> 3. **최소 코드** — TC를 통과하는 가장 단순한 구현. 과도한 추상화, 미래 대비 설계 금지
> 4. **기존 패턴 존중** — 프로젝트 내 유사 컴포넌트의 코딩 스타일, 타입 정의 방식, import 순서를 따른다
> 5. **타입 안전** — any 타입 사용 금지. 프로젝트 기존 타입 정의 활용
> 6. **경계 처리** — null/undefined 등 TC의 negative/boundary 케이스를 고려한 안전한 코드
>
> **[구현 완료 후 자체 검증]**
> QA에게 넘기기 전 반드시 직접 확인:
> 1. 빌드 명령어 실행 (프로젝트 빌드 명령 또는 린터)
> 2. TC 목록을 순서대로 읽으며 각 기대결과가 구현에 반영됐는지 확인
> 3. 변경하지 않은 기존 기능이 여전히 동작하는지 확인
>
> **[step.md 구현 결과 기록]**
> 완료 후 step.md에 `## 구현 결과` 섹션 추가:
> ```
> ## 구현 결과
> - 변경 파일: `파일명` (라인 N~M)
> - 주요 변경: (실제 구현 Before→After 핵심 1~3줄)
> - 빌드: ✅ 오류 없음
> ```
>
> **[블로킹 기준]**
> 아래 상황에서만 에스컬레이션:
> - plan.md와 실제 코드 구조가 달라 After 코드를 그대로 적용할 수 없는 경우
> - TC 기대결과가 서로 모순되거나 기술적으로 불가능한 경우
> - 변경 범위가 plan.md에 정의된 것을 크게 벗어나야 하는 경우
>
> 블로킹 보고:
> [STEP:N:블로킹:기술불가]
> 원인: (구체적 문제)
> 제안: (가능한 대안 1~2가지)
>
> **[완료 보고]**
> [STEP:N:개발완료]
> 빌드 명령: <명령어>
> 결과: ✅ 성공

#### 3-3. TDD 개발 루프 (Phase/Step 반복)

> ⚠️ **TC 작성과 개발은 병렬 진행한다. 검증은 둘 다 완료된 후.**
> QA TC 작성 + Dev 구현을 동시에 SendMessage로 지시한다.
> QA `[STEP:N:테스트정의완료]` + Dev `[STEP:N:개발완료]` 모두 수신한 후에만 QA에게 검증을 지시한다.
>
> **⚠️ 병렬 발송 필수**: SendMessage 두 호출을 **단일 응답에서 동시에 발송**한다.
> QA SendMessage 후 응답 기다린 뒤 Dev SendMessage하는 것은 순차 실행이므로 금지.
> 두 SendMessage() 호출을 같은 응답의 tool call 블록에 함께 포함해야 실제 병렬 실행된다.
> ⚠️ Dev `[STEP:N:개발완료]` + QA `[STEP:N:테스트통과]` 수신 전 응답 종료 금지. step.md ✅ 없는 상태에서 응답이 끝나면 completion-gate가 차단한다.

각 개발 Phase의 각 Step마다:

```
# QA_AGENT_ID / DEV_AGENT_ID: 3-2에서 스폰 시 받은 agentId. Phase가 바뀌어도 그대로 사용.

5-1. [단일 응답에서 동시 발송 — 두 tool call을 같은 응답에 포함]
     SendMessage(to=QA_AGENT_ID): "Phase N Step M TC 작성" 지시  ┐ 병렬
     SendMessage(to=DEV_AGENT_ID): "Phase N Step M 구현" 지시    ┘ 병렬
     → [STEP:N:테스트정의완료] 수신 (QA)
     → [STEP:N:개발완료] 수신 (Dev) — 둘 다 완료될 때까지 대기
       빌드 명령: <명령어>
       결과: ✅ 성공

5-2. SendMessage(to=QA_AGENT_ID): "Phase N Step M 검증" 지시
     → [STEP:N:테스트통과] 수신
       명령어: <명령어>
       결과: N/N 통과
     → step-M.md TC 테이블 "실제 결과" 컬럼에 ✅ 기록
     → step-M.md에 "## 실행출력" 섹션 추가하여 실제 명령어 출력 붙여넣기 (필수)
     → state.json current_step++
     ⚠️ plan-gate가 이전 step의 실행출력 존재를 검증함. 없으면 다음 step 차단.

     실패 시 → SendMessage(to=DEV_AGENT_ID): 재작업 지시
             → SendMessage(to=QA_AGENT_ID): 재검증 지시

Phase N 완료 → Phase N+1 시작: [단일 응답에서 동시 발송, 재스폰 없음]
  SendMessage(to=QA_AGENT_ID): "Phase N+1 Step 1 TC 작성" 지시  ┐ 병렬
  SendMessage(to=DEV_AGENT_ID): "Phase N+1 Step 1 구현" 지시    ┘ 병렬
```

> **phase.md 필수 섹션**: `## 목표`, `## Steps` — plan-gate가 검증하며 누락 시 코드 수정 차단.

> **step.md 필수 형식** (plan-gate CHECK 7e가 패턴 검증 — 틀리면 코드 수정 차단):
>
> ```markdown
> ## 테스트 기준
>
> | TC-ID | 유형 | 시나리오 (5자 이상) | 기대 결과 (5자 이상) | 실제 결과 |
> |-------|------|---------------------|----------------------|-----------|
> | TC-1  | <구체적 검증 시나리오> | <예상 동작 결과>    |           |
> | TC-2  | <구체적 검증 시나리오> | <예상 동작 결과>    |           |
>
> 검증 명령어: `<실행 명령어>` (backtick 필수)
> ```
>
> ⚠️ TC 행은 반드시 `| TC-1 |` 형식 — `| 1 |` 또는 `| # |` 형식 불가 (hook 차단).
> ⚠️ 시나리오·기대결과는 각 5자 이상 — 짧으면 hook 차단.
> ⚠️ backtick(`) 포함 검증 명령어 필수 — 없으면 hook 차단.
> ⚠️ 5-3 완료 후 `## 실행출력` 섹션에 실제 출력 2줄 이상 기록 필수 — 없으면 다음 step 차단.
> ⚠️ 유형 컬럼 필수 — happy/negative/boundary/e2e/integration/regression/type-check
> ⚠️ type-check TC만 있으면 품질 미달 — 다양한 유형 포함 권장

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

Dev가 `[PHASE:N:완료]` 또는 `[ALL_STEPS:완료]`를 출력하면, **Main Claude가 반드시 다음을 확인**:

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

- `NEXT_PHASE=N` → **Phase 4로 넘어가지 않는다.** Dev에게 "Phase N 개발을 시작하라"고 SendMessage.
  state.json `current_dev_phase`를 N으로 업데이트.
- `ALL_DONE` → 모든 Phase 완료. Phase 4 (검증 루프) 진행.

> **주의**: Dev가 `[ALL_STEPS:완료]`를 출력해도 state.json의 dev_phases에 남은 Phase가 있으면
> **절대 Phase 4로 넘어가지 않는다.** 남은 Phase를 먼저 모두 완료해야 한다.
> Dev가 잘못 판단할 수 있으므로 Main Claude가 직접 dev_phases 개수를 확인한다.

---

### Phase 4: 검증

⚠️ **Phase 4의 첫 번째 액션은 state.json을 `"verification"`으로 변경하는 것이다. 예외 없음.**
verifications/ 파일 쓰기, critical-reviewer 스폰 — 모두 state 변경 이후에만 가능.
development 상태에서 verifications/ 쓰기는 hook이 차단한다.

Phase 4 시작 전 state.json `workflow_phase`를 `"verification"`으로 업데이트.
(completion-gate.sh가 verification 상태에서 검증 통과 전 응답 종료를 차단)

**agent_mode별 구성:**

| agent_mode | 동작 |
|---|---|
| `team` | critical-reviewer 에이전트 스폰 (기본) |
| `subagent` | Agent tool로 critical-reviewer 스폰 |
| `single` | Main Claude가 직접 비판적 검증 수행 |

1. 비판적 리뷰어(critical-reviewer) 에이전트 스폰 (TASK_DIR 전달)
2. 리뷰어가 수행 (처음부터 끝까지 독립적으로 검토):
   - [검증 A] plan.md After 코드와 실제 변경된 소스 파일을 직접 읽어 줄 단위 비교
   - [검증 B] 각 step TC 기대결과가 실제 코드에서 충족되는지 확인
   - [검증 C] plan.md에서 다루지 않은 엣지 케이스 탐색 (null/undefined/빈 배열/빈 문자열)
   - [검증 D] 변경 파일의 기존 코드 경로 regression 없는지 확인
   - [검증 E] 빌드/타입 체크 명령어 실행
   - `verifications/e2e-result.md` 작성 (각 검증 항목 결과 포함)

> **critical-reviewer 스폰 프롬프트 (Main Claude가 아래 내용을 그대로 리뷰어에게 전달한다):**
>
> 당신은 소프트웨어 품질에 극도로 비판적인 시니어 리뷰어입니다.
> TASK_DIR: {TASK_DIR}
>
> **[역할]**
> 이 구현이 실제로 올바른지 처음부터 끝까지 독립적으로 검증합니다.
> 이전 QA 에이전트의 TC 결과를 신뢰하지 마세요 — 당신이 직접 코드를 보고 판단합니다.
>
> **[검증 순서 — 반드시 이 순서대로]**
> 1. TASK_DIR/plan.md 읽기 → 무엇을 만들기로 했는지 파악
> 2. TASK_DIR의 모든 phase-N-*/step-M.md 읽기 → 구현 기록 확인
> 3. 실제 변경된 소스 파일을 직접 Read → 실제 코드 상태 확인
> 4. 아래 검증 항목을 하나씩 수행:
>
>    [검증 A] plan.md After 코드와 실제 코드 대조 — 줄 단위로 비교
>    [검증 B] 각 step TC 기대결과가 실제 코드에서 달성됐는지 확인
>    [검증 C] plan.md에서 다루지 않은 엣지 케이스 탐색 (null/undefined/빈 배열/빈 문자열)
>    [검증 D] 변경 파일의 기존 코드 경로가 regression 없는지 확인
>    [검증 E] 빌드/타입 체크 명령어 실행
>
> 5. TASK_DIR/verifications/e2e-result.md 작성 (각 검증 항목 결과 포함)
>
> **[보고]**
> 모두 통과: [DONE]
> 이슈 발견: [E2E:실패:PHASE-P-STEP-M]
> 원인: <파일명:라인 — 구체적 문제>
> 제안: <최소 수정 방향>
>
> ⚠️ "동작할 것 같다"는 추측 금지. 실제 코드를 읽고 확인한 것만 PASS 처리.
> ⚠️ 빌드 명령어 없이 통과 처리 금지.

3. `[E2E:실패:PHASE-P-STEP-M]` 수신 시:
   - 책임 step-M.md의 해당 TC 판정 ✅→❌ 변경
   - state.json `workflow_phase = "development"` (current_dev_phase/current_step 포인터는 유지 — 이미 완료된 phase들을 재요구하지 않도록)
   - Main Claude가 Dev에게 실패한 Step 재작업 지시
   - Dev가 수정 완료 → QA가 실패 Step만 재검증 → TC ✅ 복구
   - Main Claude가 workflow_phase → "verification" 재설정 → critical-reviewer 재실행

4. `[DONE]` 수신 (verifications/e2e-result.md 전부 통과):
   - state.json `workflow_phase`를 `"done"`으로 업데이트  ← 먼저 (crash 시 done+active → 다음 세션에서 자동 정리)
   - dev_phases의 모든 팀에 대해 TeamDelete (등록된 팀 이름별로 순서대로)
     ⚠️ TeamDelete 실패 시 `rm -r ~/.claude/teams/{TEAM_NAME}`으로 직접 정리.
   - active_file 삭제: `rm -f {active_file}`             ← 그 다음
     ⚠️ task_dir 자체는 절대 삭제하지 않는다. 모든 문서 보존.
   - 사용자에게 완료 보고

---

## 주의사항

- plan-gate.sh는 아티팩트(파일/팀 디렉토리)를 직접 검증합니다. state.json 플래그 조작으로 gate를 우회할 수 없습니다.
- Bash 방어: bash-gate.sh(PreToolUse)가 쓰기 패턴을 감지하여 사전 차단합니다.
  어떤 방법으로든 Bash를 통한 gate 우회는 100% 차단됩니다.
- `[PLAN:승인됨]` 없이 코드 수정 시도 → plan-gate.sh / bash-gate.sh가 차단
- 이전 Step의 step-M.md에 ✅가 없으면 다음 Step 코드 수정 → plan-gate.sh / bash-gate.sh가 차단
- 검증 미완료(e2e-result.md 통과 필요) 상태에서 응답 종료 → completion-gate.sh가 차단
- 커밋: 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md`
- 완료 후 task_dir 삭제 금지 — active_file(`.ai-bouncer-tasks/YYYY-MM-DD/<task>/.active`)만 삭제한다
- 세션 격리: `.active` 파일은 `.ai-bouncer-tasks/YYYY-MM-DD/<task>/.active`에 위치하며 session_id를 저장. hook이 자동으로 claim한다.
- docs 구조: `.ai-bouncer-tasks/YYYY-MM-DD/task-name/` — 날짜별로 태스크 문서를 구조화
- config.json 경로: `.claude/ai-bouncer/config.json` (프로젝트 로컬) → 없으면 `~/.claude/ai-bouncer/config.json` (전역) fallback
- `enforcement_mode=prompt-only`일 때 hook이 없으므로 프롬프트 규칙만으로 워크플로우를 준수해야 한다. 차단이 아닌 가이드 역할.
- `agent_mode`에 따라 Phase 3/4의 에이전트 스폰 방식이 달라진다. config.json에서 확인 후 분기. Phase 1(계획 수립)은 항상 Main Claude가 직접 수행.
