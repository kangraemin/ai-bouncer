# ai-bouncer

> 계획 없는 코드 변경을 차단하고, 모든 구현이 계획 → 테스트 → 검증을 거치도록 강제하는 Claude Code 워크플로우 도구.

[![English](https://img.shields.io/badge/lang-English-blue)](README.md)

---

## 이게 뭔가요?

**ai-bouncer**는 Claude Code가 구조화된 개발 워크플로우를 따르도록 강제합니다 — 의도 감지부터 검증 완료까지. 승인된 계획 없이 코드를 수정하는 것을 차단하고, 매 단계마다 TDD를 적용하며, 우회 불가능한 hook 기반 강제를 사용합니다.

복잡도에 따라 모드가 결정됩니다:

```
SIMPLE (단일 기능/버그)
  요청 → 의도 분석 → 계획 → 승인 → 개발 → 검증 → 완료

NORMAL (복잡한 작업)
  요청 → 의도 분석 → 계획 → 승인
    → 개발팀 (Phase/Step TDD) → 3회 연속 검증 통과 → 완료
```

---

## 왜 필요한가요?

Claude Code는 강력하지만 기본적으로 구조가 없습니다. 가드레일 없이는:
- 요구사항을 충분히 이해하지 않고 바로 코딩에 뛰어듦
- 테스트를 건너뛰거나 사후에 작성
- 계획된 기능이 모두 구현되었는지 확인하지 않고 "완료" 선언
- 세션 중간에 컨텍스트를 잃고 오래된 상태에서 조용히 재개

ai-bouncer는 문서 기반 워크플로우를 강제하여 이를 해결합니다. 모든 에이전트는 상태를 갖지 않고(stateless), 매 턴마다 파일에서 컨텍스트를 읽어 복구합니다 — 컨텍스트 윈도우 압축에도 안정적입니다.

---

## 벤치마크

동일한 앱(YouTube 자막 추출 → AI 요약 → 채팅)을 각 5회씩 처음부터 구현한 결과:

| | dev-bounce 적용 | 미적용 |
|---|---|---|
| **API 계약 통과율** | **100%** (5/5) | 60% (3/5) |
| **가중 종합 점수** | **8.27** / 10 | 5.53 / 10 |
| 평균 시간 | 662초 (11분) | 901초 (15분) |
| 평균 비용 | $7.0 | $5.8 |
| 타임아웃 | 0회 | 1회 |

핵심 발견:

- **API 정합성이 최대 차이** — 미적용 시 프론트/백엔드 필드명이 40% 확률로 어긋남
- **27% 빠르고 더 안정적** — Gate 시스템이 삽질을 방지하고, 시간 편차도 작음
- **미적용 쪽의 설계 패턴이 더 성숙** — 하지만 API가 깨지면 무의미
- **17% 더 비쌈** — 검증 단계에서 추가 토큰 소모

> 실험 상세 보고서: [youtube-helper 레포](https://github.com/kangraemin/youtube-helper) | 스택: Flutter + FastAPI + Gemini

---

## 작동 방식

### 2-모드 워크플로우

#### 모드 선택 (Phase 0)

`intent` 에이전트가 요청을 분류합니다 (일반 질문 / 정보 부족 / 개발 작업). 개발 작업은 복잡도 평가로 진행:

| 기준 | SIMPLE | NORMAL |
|------|--------|--------|
| 변경 파일 | 1~3개 예상 | 4개 이상 또는 불확실 |
| 범위 | 단일 기능/버그/설정 | 다수 모듈 |
| 방향성 | 명확 | 설계 논의 필요 |
| 테스트 | 기존 테스트로 충분 | 새 테스트 케이스 필요 |

#### SIMPLE 모드

메인 Claude가 직접 처리 — 팀 생성 없음, phase/step 구조 없음:

1. **계획** — 코드 탐색, Before/After 스니펫 포함 `plan.md` 작성, 승인 획득
2. **TC + 개발** — `tests.md`에 테스트 케이스 작성 (테이블 + 실행출력 형식, 필수), 구현, 실제 명령어 출력을 증거로 기록
3. **검증** — 테스트 실행, 계획 대비 diff 경량 검사, 완료

#### NORMAL 모드

**Phase 1 — 계획 수립**
메인 Claude가 직접 코드베이스를 탐색하고, plan mode에 진입하여 Before/After 스니펫이 포함된 상세한 `plan.md`를 작성한 후 승인을 요청합니다.

**Phase 2 — 계획 승인**
완성된 계획이 `ExitPlanMode`를 통해 제시됩니다. 개발은 명시적 승인 뒤에만 진행. 수정 요청 시 자동으로 plan mode로 재진입.

**Phase 3 — 개발**

설정된 `agent_mode`에 따라 개발 실행 방식이 달라집니다:

| 모드 | Phase 3 (개발) | Phase 4 (검증) |
|------|---------------|----------------|
| `team` | TeamCreate → Lead + Dev + QA 에이전트 | TeamCreate로 Verifier 스폰 |
| `subagent` | Agent tool → Lead + Dev + QA 에이전트 | Agent tool로 Verifier 스폰 |
| `single` | 메인 Claude가 직접 수행 (phase/step 구조는 hook 검증용으로 유지) | 메인 Claude가 직접 3회 검증 |

`lead` 에이전트 (또는 single 모드에서는 메인 Claude)가 **기능 수**에 따라 팀 규모 결정:

| 팀 | 기준 | 구성 |
|----|------|------|
| `duo` | 2~5개 기능 | Lead + Dev (Lead가 QA 겸임) |
| `team` | 6개 이상 또는 병렬화 가능 | Lead + Dev + QA |

단계별 엄격한 TDD 루프 진행:
1. QA가 `step-M.md`에 테스트 케이스 정의 (테이블 형식 + 기대 결과)
2. Dev가 TC 통과할 최소 코드 구현
3. QA가 테스트 실행 → `step-M.md`에 실제 실행출력을 증거로 기록
4. 모든 단계 통과까지 반복 — 실행출력 증거가 없는 step은 hook이 차단

**Phase 4 — 검증**
`verifier` 에이전트가 3회 *연속* 클린 패스까지 무한 루프 실행, 각각 다른 관점:
- **Round 1 — 기능 충실도**: plan.md 준수, 문서 완성도, 기능 커버리지
- **Round 2 — 코드 품질**: 코드 리뷰, 버그, 엣지 케이스, 네이밍/스타일
- **Round 3 — 통합 & 회귀**: 전체 테스트 스위트, 파일 간 상호작용, 회귀 검사
- **실패 시 `rounds_passed`가 0으로 리셋**되고 Round 1부터 재시작

---

## 설치

### 한줄 설치

프로젝트 루트에서 실행:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

### 수동 설치

```bash
git clone https://github.com/kangraemin/ai-bouncer.git
cd ai-bouncer
bash install.sh
```

현재 프로젝트의 `.claude/`에 로컬 설치됩니다 (전역 설치 없음).

### 업데이트

```bash
bash update.sh
```

### 제거

```bash
bash uninstall.sh
```

또는 install.sh로:

```bash
bash install.sh --uninstall
```

매니페스트를 읽어 설치된 파일만 정확히 제거하고, `settings.json`의 hook 항목과 `CLAUDE.md`의 주입된 규칙 블록도 삭제합니다.

---

## 사용법

설치 후 개발 작업을 시작하려면:

```
/dev-bounce <요청 내용>
```

예시:

```
/dev-bounce JWT 기반 사용자 인증 구현
```

### 재설정

```bash
bash install.sh --config
```

---

## 설치 옵션

| 항목 | 선택지 |
|------|--------|
| `docs/` git 추적 | `y / n` |
| 커밋 전략 | `1) per-step` · `2) per-phase` · `3) none` |
| 실행 모드 | `1) hooks` (강제) · `2) prompt-only` (가이드만) |
| 에이전트 모드 | `1) team` (TeamCreate) · `2) subagent` (Agent tool) · `3) single` (메인 Claude만) |

설치 시 프로젝트의 `.claude/CLAUDE.md`에 규칙을 주입하여, Claude가 모든 코딩 작업에 자동으로 `/dev-bounce`를 사용하도록 합니다.

---

## 문서 기반 아키텍처

모든 상태는 파일에 저장됩니다. 에이전트는 상태를 갖지 않고(stateless) 매 턴 시작 시 문서를 읽어 컨텍스트를 복구합니다 — Claude의 컨텍스트 윈도우가 압축되거나 리셋되어도 안정적입니다.

### 작업별 디렉토리 구조

작업은 `docs/YYYY-MM-DD/` 아래 날짜별로 구성됩니다:

```
docs/
└── 2026-03-07/
    └── <작업명>/
        ├── .active                   # 세션 마커 (hook이 session_id 자동 claim)
        ├── plan.md                   # Before/After 스니펫 포함 계획
        ├── state.json                # 이 작업의 워크플로우 상태
        ├── phase-1-<기능>/
        │   ├── phase.md              # 범위와 완료 기준
        │   ├── step-1.md             # TC 테이블 + 구현 + 실행출력 증거
        │   └── step-2.md
        ├── phase-2-<기능>/
        │   ├── phase.md
        │   └── step-1.md
        └── verifications/
            ├── round-1.md
            ├── round-2.md
            └── round-3.md
```

세션 격리 — 각 작업은 자체 `.active` 파일을 가짐:

```
docs/
└── 2026-03-07/
    ├── user-auth/
    │   ├── .active           # 세션 A
    │   ├── plan.md
    │   └── ...
    └── profile-page/
        ├── .active           # 세션 B
        ├── plan.md
        └── ...
```

**Worktree 예외**: git worktree에서 실행 시 문서가 `~/.claude/ai-bouncer/sessions/<repo>/docs/`에 저장되고, 완료 시 메인 레포로 복사됩니다.

### state.json 스키마

```json
{
  "workflow_phase": "planning",
  "mode": "simple",
  "planning": { "no_question_streak": 0 },
  "plan_approved": false,
  "team_name": "",
  "current_dev_phase": 0,
  "current_step": 0,
  "dev_phases": {},
  "verification": { "rounds_passed": 0 },
  "task_dir": "docs/2026-03-07/user-auth",
  "active_file": "docs/2026-03-07/user-auth/.active"
}
```

### 컨텍스트 복구

세션이 중단되거나 컨텍스트 윈도우가 압축된 경우:

1. `/dev-bounce`가 `docs/YYYY-MM-DD/<task>/.active` 파일을 스캔하여 현재 세션의 활성 작업 탐색
2. `state.json`을 읽어 `workflow_phase` 판단
3. 올바른 phase에서 재개 — 기획, 개발, 또는 검증
4. 다른 세션의 미승인 기획 작업은 자동 정리

---

## 강제 Hook

9개의 hook이 `settings.json`에 자동 등록됩니다. 생명주기 이벤트 기준으로 묶으면:

**PreToolUse** — `plan-gate` (Edit/Write) · `bash-gate` (Bash)
→ 하나라도 불충족 시 ⛔ 도구 실행 차단

Edit/Write/Bash 실행 전마다 동작 — 조건 미충족이면 도구 호출 자체를 막음.

| 검사 항목 | 이유 |
|---|---|
| 계획을 세우고 승인받았어? | 계획도 없이 코드 바꾸면 안 되니까 |
| TC(테스트 기준)가 작성됐어? | 테스트 기준도 없이 구현하면 안 되니까 |
| 이전 step 테스트 통과했어? | 망가진 상태에서 다음 단계 가면 안 되니까 |
| 팀이 구성됐어? _(NORMAL + team 모드만)_ | 에이전트 없이 개발 단계 진입하면 안 되니까 |
| 테스트 미통과인데 커밋? _(Bash만)_ | 안 되는 코드 커밋하면 안 되니까 |

**PostToolUse** — `doc-reminder` (Edit/Write)
→ step 문서 없으면 ⛔ 차단

PreToolUse에서 막으면 문서 자체를 못 쓰니 — PostToolUse에서 확인: 코드는 바꿨는데 step 문서 없으면 차단.

| 검사 항목 | 이유 |
|---|---|
| step 문서가 존재해? | 문서 없이 코드만 바꾸면 추적이 안 되니까 |

**PostToolUse** — `bash-audit` (Bash)
→ 무단 변경 감지 시 🔄 자동 되돌림 (차단 아님)

PreToolUse(bash-gate)는 쓰기 패턴 차단; PostToolUse(bash-audit)는 실행 전후 git diff 비교 — 빠져나간 변경 감지 시 되돌림.

| 검사 항목 | 이유 |
|---|---|
| 몰래 파일 바꿨어? | PreToolUse를 우회하는 걸 막기 위한 2중 방어 |

**SubagentStart / SubagentStop** — `subagent-track` · `subagent-cleanup`
→ 차단 없음 — 추적만

서브 에이전트는 PreToolUse/PostToolUse 검사를 생략합니다 — Main이 이미 통과했으니 서브가 또 막힐 필요가 없기 때문. 종료 시 다른 에이전트가 재사용하지 못하도록 해제.

**Stop** — `completion-gate`
→ 검증 미완료 시 ⛔ 응답 종료 차단

Claude가 턴을 끝내려 할 때 동작 — 검증 3회 연속 통과 전까지 응답 종료를 막음.

| 검사 항목 | 이유 |
|---|---|
| 검증 3회 연속 통과했어? | 덜 된 상태로 작업 종료하는 걸 막기 위해 |

**Stop** — `stop-active-cleanup`
→ 차단 없음 — 정리만

매 Stop마다 동작 — 잠금 파일 정리. 차단 없음.

| 동작 | 이유 |
|---|---|
| 작업 완료 시 잠금 파일 자동 삭제 | 완료 후 다음 작업이 잠겨있으면 안 되니까 |

**SessionStart** — `update-check`
→ 차단 없음 — 버전 확인만

세션 시작 시 동작 — 새 버전이 있으면 조용히 안내.

| 동작 | 이유 |
|---|---|
| 최신 버전 확인 | 작업을 막지 않고 업데이트를 안내하기 위해 |

> `stop-bouncer-compat`는 팀 작업 중 미커밋 경고 오탐을 억제하기 위해 사용자의 기존 Stop hook에 inject됩니다 — 별도로 등록되는 hook이 아닙니다.


---

## 에이전트

| 에이전트 | Phase | 역할 |
|---------|-------|------|
| `intent` | 0 | 요청 분류: 일반 / 정보 부족 / 개발 작업 |
| `lead` | 3 | 팀 규모 결정, 계획을 phase와 step으로 분해, Dev/QA 오케스트레이션 |
| `dev` | 3 | 코드 구현, step 문서 갱신 |
| `qa` | 3 | 구현 전 TC 작성, 테스트 실행, 결과 기록 |
| `verifier` | 4 | 계획 대비 구현 검증, 회귀 테스트, 3회 연속 루프 관리 |

부가 파일:
- `agents/guides/tc-guide.md` — QA용 테스트 케이스 작성 가이드

---

## 프로젝트 구조

```
agents/
  intent.md            lead.md              dev.md
  qa.md                verifier.md
  guides/
    tc-guide.md

skills/
  dev-bounce/
    SKILL.md           (/dev-bounce 스킬 — 전체 플로우 오케스트레이션)

hooks/
  plan-gate.sh         bash-gate.sh         bash-audit.sh
  doc-reminder.sh      completion-gate.sh   stop-bouncer-compat.sh
  subagent-track.sh    subagent-cleanup.sh
  hooks.json           (hook 메타데이터 매니페스트)
  lib/
    resolve-task.sh    (공유 작업 해석 라이브러리)

tests/
  e2e-full.sh          (전체 생명주기: 설치 → hook → 업데이트 → 제거)
  e2e-hooks.sh         (hook 로직 테스트 — 85건)
  e2e-install.sh       (설치/제거 테스트)
  e2e-modes.sh         (에이전트 모드 조합 테스트)
  e2e-workflow.sh      (워크플로우 통합 테스트)
  e2e-restore.sh       (컨텍스트 복구 테스트)
  e2e-skill.sh         (스킬 테스트)
  test-bash-audit.sh   (bash-audit 단위 테스트)
  test-bash-gate.sh    (bash-gate 단위 테스트)
  test-completion-gate.sh (completion-gate 단위 테스트)
  test-plan-gate.sh    (plan-gate 단위 테스트)

install.sh             (설치/업데이트/설정)
uninstall.sh           (독립 제거)
update.sh              (빠른 업데이트 단축)
```

---

## 라이선스

MIT
