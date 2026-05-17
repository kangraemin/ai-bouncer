<div align="center">

# ai-bouncer

**계획 없이 Claude Code가 코드를 건드리지 못하게.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-130%2B-brightgreen?style=for-the-badge)](#테스트)

[시작하기](#설치) · [English](README.md) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

## 왜 ai-bouncer인가?

Claude Code는 강력하지만 가드레일이 없으면 제멋대로 움직입니다. 버그 하나 고쳐달라니까 세 파일을 리팩터링하고, 계획을 아직 고민 중인데 벌써 코드를 짜고, "다 됐다"면서 검증을 건너뜁니다. 작업 중간에 컨텍스트가 압축되면 어디까지 했는지 잊어버립니다.

| ai-bouncer 없이 | ai-bouncer 적용 후 |
|---|---|
| 요청 안 한 파일까지 수정 | 모든 변경은 승인된 plan이 있어야 함 |
| 합의 전에 코드부터 시작 | plan mode → 사용자 승인 → 그 다음 개발 |
| `echo > file`로 Write/Edit 우회 | bash-gate가 쓰기 패턴을 사전 차단 |
| 검증 없이 "다 됐어요" | TDD 강제 — TC 먼저, 코드 다음, 검증 마지막 |
| compact/clear로 컨텍스트·작업 유실 | 모든 진행이 `state.json`에 — 어디서든 재개 |
| 여러 세션이 서로 충돌 | `.active` 파일 락으로 세션 격리 |

---

## 기능

### 워크플로우 강제

- **plan-gate** — `ExitPlanMode`로 plan을 승인하기 전까지 모든 Write/Edit/MultiEdit 차단. 다음 step으로 넘어가기 전 step별 TC 존재·`## 실행출력` 기록·phase 문서 구조도 검사.
- **bash-gate** — 파일 쓰기 패턴(`>`, `>>`, `tee`, `sed -i`, `cat/echo/printf >`, python `open(...,'w')` 등)을 감지해 실행 전에 차단. "Bash로 Write 우회" 구멍을 막음.
- **completion-gate** — `development`/`verification` 상태에서 `verifications/e2e-result.md`가 `## 결론` → `통과`에 도달하기 전에는 turn을 끝내지 못하게 함.
- **block-logger** — 모든 gate 차단 이벤트를 기록 (사후 검토용 evidence 수집).

### 파일 기반 상태

모든 워크플로우 상태가 컨텍스트가 아닌 디스크에 존재합니다. `state.json` + `phase/step.md` + `verifications/e2e-result.md` 덕분에 compact되거나 죽은 세션도 정확히 그 위치부터 재개됩니다 — hook은 모델 기억이 아니라 파일을 읽습니다.

### Agent 모드

`max_concurrent`(`depends_on`을 Kahn 위상정렬한 결과)가 모드를 자동 결정합니다:

- **single** — Main Claude가 TC → 코드 → 검증을 직접 수행. phase/step 구조는 hook이 강제.
- **subagent** — `Agent` 도구로 phase별 Dev + QA 서브프로세스 스폰. 독립 phase 병렬 실행 시 사용.
- **team** — `TeamCreate`로 등록된 팀 스폰 (config 기본값).

### 세션 격리

각 작업은 `.ai-bouncer-tasks/YYYY-MM-DD/task-name/` 디렉토리와 세션 ID를 담은 `.active` 락을 가집니다. hook이 소유권을 검사 — 두 번째 세션이 첫 세션을 방해할 수 없고, 잔여 락은 Stop 시 자동 정리됩니다.

---

## 설치

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

대화형 위저드가 안내합니다:

1. **범위** — 글로벌(`~/.claude/`) 또는 프로젝트 로컬(`.claude/`)
2. **커밋 전략** — per-step, per-phase, none
3. **강제 모드** — `hooks`(차단) 또는 `prompt-only`(스킬 가이드, hook 없음)
4. **Agent 모드** — `team`, `subagent`, `single`

CI/비대화형 환경:

```bash
bash install.sh --ci
```

---

## 사용법

```
/dev-bounce 로그인 API에 rate limiting 추가해줘
```

이게 전부입니다. 나머지는 자동:

```
Phase 0   인텐트 판별 — 질문/탐색 → 답변, 개발 요청 → 진행
Phase 1   EnterPlanMode → 코드 탐색 → plan.md 작성 → 사용자 승인
           ↓ accept
Phase 3   Phase/Step 분해 → depends_on 분석 → phase_layers (Kahn)
           → 모드 결정 (single / subagent / team)
           → step별 TDD 루프: TC → 코드 → 검증 → 커밋
Phase 4   workflow_phase = verification → critical-reviewer 6단계 검증
           → e2e-result.md "## 결론 통과" 도달해야 done
```

### 무엇이 차단되는가

```
❌  Write("src/app.ts")            → plan-gate: plan 미승인
❌  Bash("echo 'x' > src/app.ts")  → bash-gate: bash 파일 쓰기 차단
❌  Bash("python3 -c 'open(f,\"w\")')  → bash-gate: python 파일 쓰기 감지
❌  [검증 중 turn 종료]            → completion-gate: 검증 미통과
✅  Write(".ai-bouncer-tasks/.../state.json")  → 허용 (작업 관리 파일)
✅  Bash("git status")             → 허용 (읽기 전용)
✅  Bash("npm test")               → 허용 (쓰기 패턴 없음)
```

---

## 동작 원리

### Hook 구조

| Hook | 시점 | 검사 내용 |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit/MultiEdit) | `plan_approved`, `plan.md` 존재, 이전 step.md ✅ + `## 실행출력`, phase.md 섹션, TC 형식, verification 단계 파일 범위 |
| **bash-gate.sh** | PreToolUse (Bash) | 쓰기 패턴 감지(`>`, `tee`, `sed -i`, `cp`, python write…) + 파일 쓰기 명령엔 plan-gate 동일 검사 |
| **completion-gate.sh** | Stop | 작업이 development/verification에 묶여있지 않은지, turn 종료 전 `e2e-result.md` `## 결론` → `통과` 확인 |
| **stop-active-cleanup.sh** | Stop | `workflow_phase`가 `done`/`cancelled`이면 잔여 `.active` 락 제거 |
| **subagent-track.sh** | SubagentStart | 스폰된 에이전트를 세션 추적용으로 등록 |
| **subagent-cleanup.sh** | SubagentStop | 에이전트 등록 정리 |

`hooks/lib/` 공유 헬퍼: `gate-checks.sh`(공통 검증), `resolve-task.sh`(작업 디렉토리 해석), `block-logger.sh`(차단 로깅). `stop-bouncer-compat.sh`는 구버전 config 호환용 (`hooks.json` 미등록).

### 작업 디렉토리 구조

```
.ai-bouncer-tasks/
└── 2026-05-18/
    └── add-rate-limiting/
        ├── .active                    # 세션 락 (session_id 포함)
        ├── state.json                 # 워크플로우 상태 머신
        ├── plan.md                    # 승인된 계획
        ├── phase-1-auth/
        │   ├── phase.md               # 목표 / 기술 접근 / Steps
        │   ├── step-1.md              # TC 테이블 + 실행출력
        │   └── step-2.md
        ├── phase-2-api/
        │   └── ...
        └── verifications/
            └── e2e-result.md          # critical-reviewer 6단계 결과
```

### 상태 머신

```
planning ──accept──→ development ──모든 phase 완료──→ verification ──결론 통과──→ done
    │                     │                              │
    │ reject              │ blocking                     │ 실패
    ↓                     ↓                              ↓
 cancelled          사용자 에스컬레이션            development 복귀
```

### 병렬 실행

phase 간 `depends_on`은 문서 생성 후 분석됩니다. 의존 없는 phase(`depends_on: []`)는 같은 `phase_layers` 레이어에 묶여 동시 실행. `max_concurrent ≥ 2`면 `subagent`/`team` 자동 선택, `= 1`이면 `single` 유지. 사용자 개입 없음.

---

## 설정

```bash
bash install.sh --config   # 설치 후 설정 변경
```

| 설정 | 옵션 | 기본값 | 설명 |
|---|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` | 자동 커밋 시점 |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` | hook 강제 또는 프롬프트 가이드만 |
| `agent_mode` | `team` · `subagent` · `single` | `team` | 기본 모드 (완전 직렬이면 single로 덮어씀) |
| `docs_git_track` | `true` · `false` | `false` | `.ai-bouncer-tasks/`를 git 추적 |

설정은 `.claude/ai-bouncer/config.json`(프로젝트 로컬) 또는 `~/.claude/ai-bouncer/config.json`(글로벌)에 위치.

---

## 아키텍처

```
ai-bouncer/
├── install.sh                 # 대화형 설치 (--ci, --config)
├── update.sh                  # manifest diff 기반 파일 단위 업데이트
├── uninstall.sh               # 클린 제거
├── hooks/
│   ├── hooks.json             # Hook manifest
│   ├── plan-gate.sh           # PreToolUse: Write/Edit gate
│   ├── bash-gate.sh           # PreToolUse: Bash gate
│   ├── completion-gate.sh     # Stop: 검증 gate
│   ├── stop-active-cleanup.sh # Stop: 잔여 .active 정리
│   ├── subagent-track.sh      # SubagentStart: 에이전트 등록
│   ├── subagent-cleanup.sh    # SubagentStop: 에이전트 정리
│   ├── stop-bouncer-compat.sh # 구버전 config 호환
│   └── lib/
│       ├── gate-checks.sh     # 공유 gate 검증
│       ├── resolve-task.sh    # 작업 디렉토리 해석
│       └── block-logger.sh    # 차단 이벤트 로깅
├── agents/
│   ├── intent.md              # 인텐트 분류기
│   ├── lead.md                # Lead 오케스트레이터
│   ├── dev.md                 # 개발 에이전트
│   ├── qa.md                  # QA 에이전트
│   ├── e2e-writer.md          # E2E 테스트 작성
│   └── guides/tc-guide.md     # TC 작성 가이드
├── skills/
│   ├── dev-bounce/SKILL.md    # 메인 워크플로우 스킬
│   ├── update-bouncer/SKILL.md
│   └── bouncer-status/SKILL.md
├── scripts/
│   └── bouncer-update-check.sh  # SessionStart 자동 업데이트 (24h throttle)
└── tests/                     # 130+ e2e/단위 테스트 (8개 파일)
```

---

## 테스트

8개 파일에 130+ 테스트. 각 테스트는 가짜 `$HOME`로 격리된 임시 환경을 만들어 — 실제 설정을 건드리지 않습니다.

```bash
bash tests/test-plan-gate.sh            # plan-gate 단위 (~23)
bash tests/test-bash-gate.sh            # bash-gate 단위 (~14)
bash tests/test-completion-gate.sh      # completion-gate 단위 (~31)
bash tests/test-block-logger.sh         # 차단 로거 (~10)
bash tests/test-phase-layers.sh         # Kahn 레이어 계산 (~5)
bash tests/test-delegated-team-bypass.sh # 위임 에이전트 허용 경로 (~4)
bash tests/test-e2e-workflow.sh         # 워크플로우 상태 전이 (~33)
bash tests/e2e-install.sh               # 설치/업데이트/제거 라이프사이클 (~11)
```

---

## FAQ

<details>
<summary><strong>prompt-only 모드(hook 없음)에서도 동작하나요?</strong></summary>

네. 설치 시 `enforcement_mode: prompt-only`로 설정하세요. hook 대신 SKILL.md 프롬프트로 워크플로우를 가이드합니다. Claude가 plan→승인→개발→검증 흐름을 자발적으로 따릅니다. 덜 엄격하지만 hook을 원치 않을 때 동작합니다.
</details>

<details>
<summary><strong>기존 프로젝트에 쓸 수 있나요?</strong></summary>

네. 프로젝트 디렉토리에서 설치 후 로컬 범위를 선택하세요. `.claude/`와 `.ai-bouncer-tasks/` 아래에만 파일을 추가 — `.gitignore`(관리 블록) 외 기존 파일은 수정하지 않습니다.
</details>

<details>
<summary><strong>hook이 막으면 안 되는 걸 막으면?</strong></summary>

이슈로 알려주세요. 우회책으로 Claude Code의 `! command` prefix는 hook을 거치지 않고 터미널에서 직접 실행됩니다. 또는 `prompt-only` 모드로 임시 전환하세요.
</details>

<details>
<summary><strong>멀티 세션은 어떻게 동작하나요?</strong></summary>

`/dev-bounce` 호출마다 세션 ID를 담은 `.active` 파일과 함께 작업 디렉토리가 생성됩니다. hook이 소유권을 검사 — 다른 세션이 파일을 수정하려 하면 차단됩니다. 작업 완료 시 `.active`가 제거됩니다 (잔여 락은 Stop 시 자동 정리).
</details>

<details>
<summary><strong>Agent 모드는 어떻게 정해지나요?</strong></summary>

자동입니다. phase/step 문서 생성 후 `depends_on`을 분석하고 Kahn 위상정렬로 `phase_layers`를 계산합니다. 최대 동시 phase 수가 1이면 `single`, 2 이상이면 설정된 `team`/`subagent` 모드를 씁니다. 직접 고르지 않습니다.
</details>

---

## 업데이트

```
/update-bouncer
```

또는 `SessionStart`에서 자동 체크 (24h throttle). manifest diff로 변경된 파일만 덮어씁니다.

## 제거

```bash
bash uninstall.sh
```

`settings.json`에서 hook·agent·skill·config 제거. `.ai-bouncer-tasks/` 작업 문서는 보존.

## 기여

1. 저장소 Fork
2. feature 브랜치 생성
3. 테스트 실행 (예: `bash tests/test-plan-gate.sh`)
4. Pull Request 오픈

## 라이선스

MIT

---

<p align="center">
  <a href="https://claude.com/claude-code">Claude Code</a>를 위해 <a href="https://github.com/kangraemin">@kangraemin</a>이 제작
  <br />
  <sub>무단 수정으로부터 코드베이스를 지켰다면 star를 눌러주세요.</sub>
</p>
</div>
