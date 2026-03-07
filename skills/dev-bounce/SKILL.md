---
name: dev-bounce
description: 구조화된 개발 flow 실행. 코드 수정/기능 구현/버그 수정 등 개발 작업 시 사용. 복잡도에 따라 SIMPLE(직접 개발)/NORMAL(팀 기반 개발) 모드 자동 분기.
---

# dev-bounce

복잡도에 따라 두 가지 모드로 분기:
- **SIMPLE**: Main Claude가 직접 계획·개발·검증 (팀/phase/step 없음)
- **NORMAL**: Planning Team → 계획 수립 → 승인 → Dev Team → TDD 개발 → 3회 연속 검증

계획 승인 없이는 코드를 수정하지 않는다.

**주의: plan-gate.sh + bash-gate.sh(2-layer)는 아티팩트를 직접 검증합니다. Write/Edit뿐 아니라 Bash를 통한 파일 쓰기도 차단됩니다.**

---

## 컨텍스트 복원 (세션 재시작 시)

시작 전 활성 작업 확인 (세션별 격리 — `docs/<task>/.active` 방식):

```bash
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

# docs/<task>/.active 스캔 (persistent → local 순서)
TASK_NAME=""
for base in "$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs" "docs"; do
  [ -d "$base" ] || continue
  for active_file in "$base"/*/.active; do
    [ -f "$active_file" ] || continue
    task_folder=$(basename "$(dirname "$active_file")")
    state_json="${base}/${task_folder}/state.json"
    [ -f "$state_json" ] || continue
    TASK_NAME="$task_folder"
    STATE_JSON="$state_json"
    TASK_DIR="${base}/${task_folder}"
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

판별 후 state.json에 `"mode": "simple"` 또는 `"mode": "normal"` 설정.

- `mode: simple` → Phase S1 진행
- `mode: normal` → Phase 1 진행

---

## SIMPLE 모드

### Phase S1: 계획 수립

Main Claude가 직접 수행 (팀 스폰 없음):

1. EnterPlanMode 호출
2. 관련 코드 탐색 (Read/Grep/Glob)
3. 필요시 사용자에게 AskUserQuestion 1~2회
4. `{TASK_DIR}/plan.md` 직접 작성 — 간결하게:
   ```markdown
   # <작업 제목>
   ## 변경 사항
   - 파일: 변경 내용
   ## 검증
   - 검증 방법
   ```
5. 사용자에게 계획 표시 + ExitPlanMode
6. 승인 대기

### Phase S2: 승인 + 개발

승인 신호 감지: `승인`, `시작`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`

```python
import json, os
f = os.path.join(task_dir, 'state.json')
with open(f) as fp: s = json.load(fp)
s['plan_approved'] = True
s['workflow_phase'] = 'development'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
```

Main Claude가 직접 코드 수정 (phase/step 구조 없이 자유롭게).

### Phase S3: 검증 + 완료

개발 완료 후:

1. 테스트 실행 (pytest, lint 등) — 1회 통과면 OK
2. active_file 삭제 (workflow_phase가 아직 whitelisted일 때): `rm -f {active_file}`
3. state.json `workflow_phase`를 `"done"`으로 업데이트 (state.json은 bash-gate 예외 경로):
   ```python
   import json, os
   f = os.path.join(task_dir, 'state.json')
   with open(f) as fp: s = json.load(fp)
   s['workflow_phase'] = 'done'
   with open(f, 'w') as fp: json.dump(s, fp, indent=2)
   ```
4. 사용자에게 완료 보고

---

## NORMAL 모드

### Phase 1: Planning Team + Q&A 루프

#### 1-0. Plan Mode 진입

EnterPlanMode 호출 — Planning 전체(Q&A + 계획 수립)를 plan mode 안에서 진행한다.

#### 1-1. TASK_DIR 초기화

요청에서 작업 이름 추출 (영어 소문자, 하이픈 구분):

```python
import json, os, subprocess

TASK_NAME = "user-auth"  # 예: 요청에서 핵심 키워드 추출

git_dir = subprocess.run(["git", "rev-parse", "--git-dir"],
    capture_output=True, text=True).stdout.strip()
is_worktree = "worktrees" in git_dir

cfg_path = os.path.expanduser("~/.claude/ai-bouncer/config.json")
cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
docs_git_track = cfg.get("docs_git_track", True)

repo_root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
    capture_output=True, text=True).stdout.strip()
repo_name = os.path.basename(repo_root)

persistent_mode = is_worktree or not docs_git_track
if persistent_mode:
    docs_base = os.path.expanduser(f"~/.claude/ai-bouncer/sessions/{repo_name}/docs")
else:
    docs_base = os.path.join(repo_root, "docs")

task_dir = os.path.join(docs_base, TASK_NAME)
active_file = os.path.join(task_dir, ".active")  # 태스크 폴더 안에 .active
os.makedirs(task_dir, exist_ok=True)
# .active는 빈 마커로 생성 — 첫 hook이 session_id를 기록 (자동 claim)
with open(active_file, "w") as f:
    f.write("")

state = {
    "workflow_phase": "planning",
    "mode": "normal",
    "planning": {"no_question_streak": 0},
    "plan_approved": False,
    "team_name": "",
    "current_dev_phase": 0,
    "current_step": 0,
    "dev_phases": {},
    "verification": {"rounds_passed": 0},
    "task_dir": task_dir,
    "active_file": active_file,
    "persistent_mode": persistent_mode,
}
with open(os.path.join(task_dir, "state.json"), "w") as f:
    json.dump(state, f, indent=2)
print(f"state.json initialized at {task_dir} (persistent_mode={persistent_mode})")
```

#### 1-2. Planning Team 구성

```
TeamCreate: planning-<task>
  - planner-lead (planner-lead.md) — 리드
  - planner-dev (planner-dev.md) — 기술 관점
  - planner-qa (planner-qa.md) — 품질 관점
```

팀에게 전달: 요청 원문 + TASK_DIR + 관련 코드 컨텍스트

#### 1-3. Q&A 루프

> ⚠️ **Q&A 루프 중 ExitPlanMode 절대 금지.**
> planner-lead로부터 질문을 받아 사용자에게 전달할 때는 반드시 **AskUserQuestion** 사용.
> ExitPlanMode는 plan.md 작성 완료 후 **Phase 1-5에서만** 호출한다.

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

#### 1-4. 계획 확정

planner-lead에게 "계획 확정" 요청 → `[PLAN:완성]` 수신.
Main Claude가 planner-lead의 계획 내용을 `{TASK_DIR}/plan.md`에 Write tool로 직접 저장.
(plan-gate.sh가 `*/plan.md` 경로를 예외 허용하므로 planning 단계에도 가능)
저장 후 파일 존재 확인 후에만 Phase 1-5 진행.

Planning 팀 shutdown.

#### 1-5. 계획 사용자에게 표시

`{TASK_DIR}/plan.md` 내용 표시:

```
[PLAN:승인대기]

<plan.md 내용>

수정 요청이 있으면 말씀해주세요. 승인하시면 개발을 시작합니다.
```

ExitPlanMode 호출 — plan.md를 플랜 파일로 사용하여 사용자 승인 요청.

---

### Phase 2: 계획 승인 처리

승인 신호 감지: `승인`, `시작`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`

수정 요청 시: EnterPlanMode 재진입 → planner-lead에게 재작업 지시 → 1-3 Q&A 루프 재시작

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

`~/.claude/ai-bouncer/config.json`에서 커밋 전략 확인:

```bash
python3 -c "
import json
cfg = json.load(open('$HOME/.claude/ai-bouncer/config.json'))
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

Phase 4 시작 전 state.json `workflow_phase`를 `"verification"`으로 업데이트:

```python
import json, os
f = os.path.join(task_dir, 'state.json')
with open(f) as fp: s = json.load(fp)
s['workflow_phase'] = 'verification'
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
print('workflow_phase = verification')
```

1. verifier 에이전트 스폰 (TASK_DIR 전달)
2. verifier가 검증 루프 실행 (시도 횟수 제한 없음)
3. `[VERIFICATION:N:실패:PHASE-P-STEP-M]` 수신:
   - Dev/QA에게 해당 Step 재작업 지시
   - 재작업 완료 후 verifier에게 "재검증 시작" 요청
4. `[DONE]` 수신 (verifications/round-*.md 3개 연속 통과):
   - verifier + 전체 팀 shutdown
   - persistent_mode이면 Phase 4-4 실행: main repo의 `docs/<task>/`로 복사:
     ```python
     import json, os, shutil, subprocess
     with open(os.path.join(task_dir, "state.json")) as fp: state = json.load(fp)
     if state.get("persistent_mode"):
         git_common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
             capture_output=True, text=True).stdout.strip()
         main_root = os.path.dirname(os.path.abspath(git_common))
         task_name = os.path.basename(state["task_dir"])
         dst = os.path.join(main_root, "docs", task_name)
         if os.path.exists(dst):
             shutil.rmtree(dst)   # destination(main repo)만 삭제, source(persistent)는 보존
         shutil.copytree(state["task_dir"], dst)
     ```
   - active_file 삭제 (workflow_phase가 아직 verification일 때): `rm -f {active_file}`
   - state.json `workflow_phase`를 `"done"`으로 업데이트 (state.json은 bash-gate 예외 경로)
     ⚠️ task_dir(source) 자체는 절대 삭제하지 않는다. 모든 문서 보존.
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
- 완료 후 task_dir(source) 삭제 금지 — active_file(`docs/<task>/.active`)만 삭제한다
- 세션 격리: `.active` 파일은 `docs/<task>/.active`에 위치하며 session_id를 저장. hook이 자동으로 claim한다.
- persistent_mode에서 `shutil.rmtree(dst)`는 destination(main repo)만 삭제, source(persistent)는 보존
