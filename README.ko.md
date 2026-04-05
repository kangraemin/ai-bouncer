<div align="center">

# ai-bouncer

**Claude Code가 계획 없이 코드를 건드리지 못하게 합니다.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-750%2B-brightgreen?style=for-the-badge)](#tests)

[Getting Started](#설치) · [English](README.md) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

## 왜 ai-bouncer인가?

Claude Code는 강력하지만, 가드레일 없이 쓰면 종종 제멋대로 움직입니다. 버그 하나 고쳐달랬는데 파일 세 개를 리팩터링하고, 아직 계획을 생각하는 중인데 이미 코드를 쓰고 있고, 검증도 없이 "완료했습니다"라고 합니다.

| ai-bouncer 없이 | ai-bouncer 있을 때 |
|---|---|
| 요청하지 않은 파일까지 수정 | 모든 변경에 승인된 계획이 필요 |
| 합의 전에 코드부터 작성 | Plan mode → 사용자 승인 → 그 다음 개발 |
| `echo > file`로 Write/Edit 제한 우회 | 2-layer Bash 방어가 모든 파일 쓰기를 잡음 |
| 검증 없이 "완료" 처리 | TDD 강제: TC 먼저, 코드 다음, 검증 마지막 |
| 여러 세션이 서로 간섭 | `.active` 파일 잠금으로 세션 격리 |

---

## 주요 기능

### 워크플로우 강제

- **Plan-gate** — `ExitPlanMode`로 계획을 승인받기 전까지 모든 Write/Edit을 차단합니다
- **Bash-gate** — 15가지 이상의 쓰기 패턴(`>`, `tee`, `sed -i`, `cp`, `curl -o` 등)을 감지하여 실행 전에 차단합니다
- **Bash-audit** — 실행 후 git diff 스냅샷을 비교하여 bash-gate가 놓친 무단 변경을 자동 복원합니다
- **Completion-gate** — 검증이 통과되기 전까지 Claude가 대화를 종료할 수 없습니다

### 개발 모드

- **SIMPLE** — 작은 변경(3파일, 50줄 이하)용. Main Claude가 계획, 코드, 테스트, 완료까지 직접 처리합니다.
- **NORMAL** — 큰 작업용. Dev Team(Lead + Dev + QA)을 스폰하고 step마다 TDD 루프를 돌립니다. 마지막에 3라운드 통합 검증.

### 멀티 에이전트

- **Team 모드** — `TeamCreate`로 실제 팀을 구성합니다. Lead가 오케스트레이션, Dev가 구현, QA가 검증.
- **Subagent 모드** — `Agent` 도구로 경량 서브프로세스를 스폰합니다. 같은 워크플로우, 적은 오버헤드.
- **Single 모드** — Main Claude가 전부 직접 수행합니다. Phase/step 구조는 hook이 여전히 강제합니다.

### 세션 격리

각 작업은 `.ai-bouncer-tasks/YYYY-MM-DD/task-name/` 디렉토리를 가지며, `.active` 잠금 파일에 세션 ID가 저장됩니다. hook이 소유권을 확인하므로 다른 세션이 간섭할 수 없습니다.

---

## 설치

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

대화형 설치 마법사가 안내합니다:

1. **범위** — 전역(`~/.claude/`) 또는 프로젝트 로컬(`.claude/`)
2. **커밋 전략** — Step마다, Phase마다, 또는 수동
3. **실행 모드** — hook 강제 또는 프롬프트 가이드(hook 없이 스킬로만)
4. **에이전트 모드** — Team, Subagent, 또는 Single

CI/비대화형 환경:

```bash
bash install.sh --ci
```

---

## 사용법

```
/dev-bounce 로그인 API에 rate limiting 추가해줘
```

이것만 입력하면 나머지는 자동입니다:

```
Phase 0   인텐트 판별 — 질문이면 답변, 개발 요청이면 진행
Phase 1   계획 수립 → EnterPlanMode → 코드 탐색 → 계획 작성 → 사용자 승인
           ↓ accept
Phase 1-B 복잡도 판별 → SIMPLE 또는 NORMAL
           ↓
Phase 2   SIMPLE: TC → 코드 → 검증 → 커밋 → 완료
Phase 3   NORMAL: Lead 스폰 → phase/step 분해 → TDD 루프
Phase 4   NORMAL: 3라운드 통합 검증 → 완료
```

### 차단 예시

```
❌  Write("src/app.ts")              → plan-gate: "계획이 승인되지 않았습니다"
❌  Bash("echo 'x' > src/app.ts")   → bash-gate: "Bash를 통한 파일 쓰기가 차단되었습니다"
❌  Bash("python3 -c 'open(f,w)')   → bash-gate: python 파일 쓰기 감지
❌  [검증 중 세션 종료 시도]           → completion-gate: "검증이 완료되지 않았습니다"
✅  Write("state.json")             → 허용 (작업 관리 파일)
✅  Bash("git status")              → 허용 (읽기 전용)
✅  Bash("npm test")                → 허용 (쓰기 패턴 없음)
```

---

## 동작 원리

### Hook 아키텍처

| Hook | 이벤트 | 검증 내용 |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit) | `plan_approved`, `plan.md` 존재, 팀 구성, step TC, phase.md 섹션 |
| **bash-gate.sh** | PreToolUse (Bash) | 쓰기 패턴 감지, 파일 쓰기 명령에 대해 plan-gate와 동일한 검증 |
| **bash-audit.sh** | PostToolUse (Bash) | git diff 전후 스냅샷 비교, 무단 변경 자동 복원 |
| **completion-gate.sh** | Stop | `round-*.md` 3개 + "통과" 포함 필요 |
| **doc-reminder.sh** | PostToolUse (Write/Edit) | 코드 변경 후 TC/문서 작성 알림 |
| **subagent-track.sh** | SubagentStart | 스폰된 에이전트 세션 등록 |
| **subagent-cleanup.sh** | SubagentStop | 에이전트 등록 정리 |

### 2-Layer Bash 방어

```
                    Bash("echo 'x' > src/app.ts")
                              │
                    ┌─────────▼──────────┐
        Layer 1     │    bash-gate.sh    │   PreToolUse
                    │  패턴 감지          │
                    │  15가지 이상 쓰기   │
                    └──────┬─────────────┘
                           │ 차단 → ⛔ REJECT
                           │ 미감지 ↓
                    ┌──────▼─────────────┐
        Layer 2     │   bash-audit.sh    │   PostToolUse
                    │  git diff 스냅샷    │
                    │  실행 전후 비교      │
                    └──────┬─────────────┘
                           │ 변경 감지 → 🔄 자동 복원
                           │ 클린    → ✅ 통과
```

### 작업 디렉토리 구조

```
.ai-bouncer-tasks/
└── 2026-04-04/
    └── add-rate-limiting/
        ├── .active                    # 세션 잠금 (session_id 저장)
        ├── state.json                 # 워크플로우 상태 머신
        ├── plan.md                    # 승인된 계획
        ├── tests.md                   # SIMPLE 모드 TC
        ├── phase-1-auth/              # NORMAL 모드
        │   ├── phase.md               # 목표, 범위, steps
        │   ├── step-1.md              # TC + 구현 + 실행 결과
        │   └── step-2.md
        └── verifications/             # NORMAL 모드
            ├── round-1.md
            ├── round-2.md
            └── round-3.md
```

### 상태 머신

```
planning ──승인──→ development ──전체 step 완료──→ verification ──3라운드 통과──→ done
    │                   │                              │
    │ 거부              │ 블로킹                        │ 실패
    ↓                   ↓                              ↓
 cancelled        사용자에게 에스컬레이션         development로 복귀
```

---

## 설정

```bash
bash install.sh --config   # 설치 후 설정 변경
```

| 설정 | 옵션 | 기본값 | 설명 |
|---|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` | 자동 커밋 시점 |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` | hook 강제 또는 프롬프트 가이드 |
| `agent_mode` | `team` · `subagent` · `single` | `team` | 에이전트 스폰 방식 |
| `docs_git_track` | `true` · `false` | `false` | `.ai-bouncer-tasks/` git 추적 여부 |

---

## 프로젝트 구조

```
ai-bouncer/
├── install.sh                 # 대화형 설치 (--ci, --config 지원)
├── update.sh                  # 매니페스트 기반 파일 업데이트
├── uninstall.sh               # 완전 제거
├── hooks/
│   ├── hooks.json             # Hook 매니페스트 (동적 설치)
│   ├── plan-gate.sh           # PreToolUse: Write/Edit 게이트
│   ├── bash-gate.sh           # PreToolUse: Bash 게이트
│   ├── bash-audit.sh          # PostToolUse: Bash 감사 + 복원
│   ├── completion-gate.sh     # Stop: 검증 게이트
│   ├── doc-reminder.sh        # PostToolUse: 문서 알림
│   ├── subagent-track.sh      # SubagentStart: 에이전트 등록
│   ├── subagent-cleanup.sh    # SubagentStop: 에이전트 정리
│   └── lib/
│       └── resolve-task.sh    # 공유: 작업 디렉토리 해석
├── agents/
│   ├── intent.md              # 인텐트 분류
│   ├── lead.md                # Lead 오케스트레이터
│   ├── dev.md                 # 개발자 에이전트
│   ├── qa.md                  # QA 에이전트
│   └── verifier.md            # 통합 검증자
├── skills/
│   ├── dev-bounce/SKILL.md    # 메인 워크플로우 스킬
│   ├── update-bouncer/SKILL.md
│   └── bouncer-status/SKILL.md
├── scripts/
│   └── bouncer-update-check.sh        # SessionStart 자동 업데이트 (24시간 throttle)
└── tests/                     # 750건 이상 e2e 테스트
```

---

## 테스트

750건 이상, 13개 파일. 모든 테스트는 격리된 임시 환경(`FAKE_HOME`)에서 실행되어 실제 설정을 건드리지 않습니다.

```bash
bash tests/e2e-full.sh           # 설치/업데이트/삭제 (74건)
bash tests/e2e-hooks.sh          # hook 동작 — 전 모드 (123건)
bash tests/e2e-modes.sh          # enforcement/agent 모드 조합 (106건)
bash tests/e2e-install.sh        # 설치 시나리오 + 마이그레이션 (130건)
bash tests/e2e-workflow.sh       # 워크플로우 상태 전이 (105건)
bash tests/e2e-isolation.sh      # 다중 세션 격리 (47건)
bash tests/e2e-recovery.sh       # 크래시 복구 + 엣지 케이스 (73건)
bash tests/e2e-restore.sh        # 컨텍스트 복원 (17건)
bash tests/e2e-skill.sh          # SKILL.md 경로 로직 (8건)
bash tests/test-plan-gate.sh     # plan-gate 단위 (25건)
bash tests/test-bash-gate.sh     # bash-gate 단위 (33건)
bash tests/test-completion-gate.sh # completion-gate 단위 (11건)
bash tests/test-bash-audit.sh    # bash-audit 단위 (10건)
```

---

## FAQ

<details>
<summary><strong>prompt-only 모드(hook 없이)에서도 작동하나요?</strong></summary>

네. 설치 시 `enforcement_mode: prompt-only`를 선택하면 됩니다. SKILL.md 프롬프트가 워크플로우를 안내합니다. hook 강제보다 덜 엄격하지만, hook이 필요 없는 환경에서 사용할 수 있습니다.
</details>

<details>
<summary><strong>기존 프로젝트에서 쓸 수 있나요?</strong></summary>

네. 프로젝트 디렉토리에서 설치하고 로컬 범위를 선택하면 됩니다. `.claude/`와 `.ai-bouncer-tasks/` 아래에만 파일을 추가하며, `.gitignore`(managed block)를 제외하고 기존 파일을 수정하지 않습니다.
</details>

<details>
<summary><strong>hook이 잘못 차단하면 어떻게 하나요?</strong></summary>

이슈로 보고해주세요. 임시 우회로는 Claude Code에서 `! command` 접두사를 사용하면 터미널에서 직접 실행되어 hook을 우회합니다. 또는 `prompt-only` 모드로 일시 전환할 수 있습니다.
</details>

<details>
<summary><strong>다중 세션은 어떻게 동작하나요?</strong></summary>

`/dev-bounce` 호출마다 작업 디렉토리가 생성되고 `.active` 파일에 세션 ID가 저장됩니다. hook이 소유권을 확인하므로 다른 세션이 수정을 시도하면 차단됩니다. 작업이 완료되면 `.active`가 제거됩니다.
</details>

<details>
<summary><strong>Claude Code 팀(TeamCreate)을 지원하나요?</strong></summary>

네, 기본 `team` 모드입니다. Lead가 오케스트레이션하고 Main Claude가 Dev/QA를 스폰합니다. 더 가벼운 설정은 `subagent`(Agent tool) 또는 `single`(에이전트 없음)을 사용하세요.
</details>

---

## 업데이트

```
/update-bouncer
```

또는 `SessionStart`에서 자동 체크 (24시간 throttle). 매니페스트 diffing으로 변경된 파일만 덮어씁니다.

## 제거

```bash
bash uninstall.sh
```

hook, agent, skill, 설정을 `settings.json`에서 제거합니다. `.ai-bouncer-tasks/` 작업 문서는 보존됩니다.

## 기여

1. 레포지토리를 Fork합니다
2. Feature 브랜치를 생성합니다
3. 테스트 스위트를 실행합니다: `bash tests/e2e-full.sh`
4. Pull Request를 엽니다

## 라이선스

MIT

---

<p align="center">
  <a href="https://claude.com/claude-code">Claude Code</a>를 위해 만들었습니다 — <a href="https://github.com/kangraemin">@kangraemin</a>
  <br />
  <sub>무단 코드 수정으로부터 프로젝트를 지켜줬다면 별 하나 부탁드립니다.</sub>
</p>
</div>
