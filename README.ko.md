# ai-bouncer

> 계획 없는 코드 변경을 차단하고, 모든 구현이 계획 → 테스트 → 검증을 거치도록 강제하는 Claude Code 워크플로우 도구.

[![English](https://img.shields.io/badge/lang-English-blue)](README.md)

---

## 이게 뭔가요?

**ai-bouncer**는 Claude Code가 구조화된 개발 워크플로우를 따르도록 강제합니다 — 의도 감지부터 검증 완료까지. 승인된 계획 없이 코드를 수정하는 것을 차단하고, 매 단계마다 TDD를 적용하며, 우회 불가능한 hook 기반 강제를 사용합니다.

복잡도에 따라 모드가 결정됩니다:

```
SIMPLE (단일 기능)
  요청 → 의도 분석 → 계획 → 승인 → 개발 → 테스트 → 완료

NORMAL (복잡한 작업)
  요청 → 의도 분석 → 기획팀 + Q&A → 계획 승인
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
| 범위 | 단일 기능/버그/설정 | 다수 모듈 |
| 방향성 | 명확 | 설계 논의 필요 |
| 테스트 | 기존 테스트로 충분 | 새 테스트 케이스 필요 |

#### SIMPLE 모드

메인 Claude가 직접 처리 — 팀 생성 없음, phase/step 구조 없음:

1. **계획** — 코드 탐색, `plan.md` 작성, 승인 획득
2. **TC + 개발** — `tests.md`에 테스트 케이스 작성 (해당 없으면 `[TC:스킵]`), 구현
3. **검증** — 테스트 실행, 계획 대비 diff 경량 검사, 완료

#### NORMAL 모드

**Phase 1 — 기획팀**
3명의 에이전트 (`planner-lead`, `planner-dev`, `planner-qa`)가 Q&A 루프를 통해 상위 계획을 수립합니다 — **plan mode** 안에서 실행되어 사용자에게 구조화된 리뷰 UI 제공:
- `planner-lead`가 루프를 주도하고 명확화 질문 제시
- `planner-dev`가 기술적 실현 가능성과 리스크 분석 기여
- `planner-qa`가 테스트 가능성과 엣지 케이스 분석 기여
- 3회 연속 **새 질문 없음**이면 루프 종료

**Phase 2 — 계획 승인**
완성된 계획이 `ExitPlanMode`를 통해 제시됩니다. 개발은 명시적 승인 뒤에만 진행. 수정 요청 시 자동으로 plan mode로 재진입.

**Phase 3 — 개발**
`lead` 에이전트가 **기능 수**에 따라 팀 규모 결정:

| 팀 | 기준 | 구성 |
|----|------|------|
| `solo` | 단일 기능 | Lead가 Dev+QA 겸임 |
| `duo` | 2–5개 기능 | Lead + Dev |
| `team` | 6개 이상 또는 병렬화 가능 | Lead + Dev + QA |

단계별 엄격한 TDD 루프 진행:
1. QA가 테스트 케이스 정의 → `step-M.md`
2. Dev가 최소 코드 구현 → `step-M.md`
3. QA가 테스트 실행 → 결과 기록
4. 모든 단계 통과까지 반복

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
bash install.sh --update
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

### 커밋 전략 재설정

```bash
bash install.sh --config
```

---

## 문서 기반 아키텍처

모든 상태는 파일에 저장됩니다. 에이전트는 상태를 갖지 않고(stateless) 매 턴 시작 시 문서를 읽어 컨텍스트를 복구합니다 — Claude의 컨텍스트 윈도우가 압축되거나 리셋되어도 안정적입니다.

### 작업별 디렉토리 구조

작업은 `docs/YYYY-MM-DD/` 아래 날짜별로 구성됩니다:

```
docs/
└── 2026-03-07/
    └── <작업명>/
        ├── .active                   # 세션 마커 (session_id 포함)
        ├── plan.md                   # 상위 계획 (planner-lead 작성)
        ├── state.json                # 이 작업의 워크플로우 상태
        ├── phase-1-<기능>/
        │   ├── phase.md              # 범위와 완료 기준
        │   ├── step-1.md             # TC + 구현 + 테스트 결과
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
  "active_file": "docs/2026-03-07/user-auth/.active",
  "persistent_mode": false
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

7개의 hook이 `settings.json`에 자동 등록됩니다:

| Hook | 트리거 | 동작 |
|---|---|---|
| `plan-gate.sh` | `PreToolUse` (Write/Edit) | 기획 중 또는 TC 정의 전 코드 편집 차단 |
| `bash-gate.sh` | `PreToolUse` (Bash) | 기획 중 Bash 쓰기 패턴 (`>`, `tee`, `sed -i`, `cp` 등) 차단 |
| `bash-audit.sh` | `PostToolUse` (Bash) | `git diff`로 미승인 파일 변경 감지 후 자동 되돌림 |
| `doc-reminder.sh` | `PostToolUse` (Write/Edit) | 코드 변경 후 step 문서 미갱신 시 경고 |
| `completion-gate.sh` | `Stop` | 검증이 3회 연속 통과에 도달하지 않으면 응답 완료 차단 |
| `subagent-track.sh` | `SubagentStart` | 서브에이전트 세션을 부모 작업에 등록 |
| `subagent-cleanup.sh` | `SubagentStop` | 종료 시 서브에이전트를 승인 목록에서 제거 |

**2중 Bash 방어**: `bash-gate.sh`가 실행 전 쓰기 패턴을 차단하고, `bash-audit.sh`가 실행 후 `git diff`로 빠져나간 것을 잡아 자동 되돌립니다. Bash 기반 gate 우회가 완전 차단됩니다.

**서브에이전트 위임**: 서브에이전트가 생성되면 `subagent-track.sh`가 부모 작업의 컨텍스트에 등록합니다. 위임된 에이전트는 부모 세션의 gate 권한을 상속받아, plan-gate나 bash-gate에 차단되지 않고 파일을 작성할 수 있습니다.

---

## 에이전트

| 에이전트 | Phase | 역할 |
|---------|-------|------|
| `intent` | 0 | 요청 분류: 일반 / 정보 부족 / 개발 작업 |
| `planner-lead` | 1 | Q&A 루프 주도, `plan.md` 확정 및 작성 |
| `planner-dev` | 1 | 기술적 실현 가능성과 리스크 분석 기여 |
| `planner-qa` | 1 | 테스트 가능성과 엣지 케이스 분석 기여 |
| `lead` | 3 | 팀 규모 결정, 계획을 phase와 step으로 분해 |
| `dev` | 3 | 코드 구현, step 문서 갱신 |
| `qa` | 3 | 구현 전 TC 작성, 테스트 실행, 결과 기록 |
| `verifier` | 4 | 계획 대비 구현 검증, 회귀 테스트, 3회 연속 루프 관리 |

---

## 설치 옵션

| 항목 | 선택지 |
|------|--------|
| 커밋 전략 | `1) per-step` · `2) per-phase` · `3) none` |
| `docs/` git 추적 | `y / n` |

설치 시 프로젝트의 `.claude/CLAUDE.md`에 규칙을 주입하여, Claude가 모든 코딩 작업에 자동으로 `/dev-bounce`를 사용하도록 합니다.

---

## 프로젝트 구조

```
agents/
  intent.md          planner-lead.md    planner-dev.md
  planner-qa.md      lead.md            dev.md
  qa.md              verifier.md

skills/
  dev-bounce/
    SKILL.md         (/dev-bounce 스킬 — 전체 플로우 오케스트레이션)

hooks/
  plan-gate.sh       bash-gate.sh       bash-audit.sh
  doc-reminder.sh    completion-gate.sh
  subagent-track.sh  subagent-cleanup.sh
  lib/
    resolve-task.sh  (공유 작업 해석 라이브러리)

tests/
  e2e-hooks.sh       (E2E hook 테스트 — 25건)

install.sh           (설치/업데이트/설정)
uninstall.sh         (독립 제거)
```

---

## 라이선스

MIT
