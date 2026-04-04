<div align="center">

# ai-bouncer

**Claude Code가 계획 없이 코드를 수정하는 걸 막는다.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-750%2B-brightgreen?style=for-the-badge)](#tests)

[Getting Started](#install) · [How It Works](#how-it-works) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

Claude Code는 강력하지만 요청하지 않은 코드를 수정하거나, 계획 승인 없이 개발을 시작하거나, 검증 없이 완료 처리하는 경우가 있다.

ai-bouncer는 **hook 기반 강제 워크플로우**로 이 문제를 해결한다.

- **Plan → Approve → Develop → Verify** — 승인 없이 코드 수정 불가
- **2-layer Bash 방어** — Write/Edit뿐 아니라 Bash를 통한 우회도 차단
- **TDD 강제** — TC 작성 → 구현 → 검증, step 단위로 잠금
- **다중 세션 격리** — 같은 프로젝트에서 여러 세션이 서로 간섭하지 않음

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

대화형 설치 마법사가 실행된다:

1. **범위** — 전역(`~/.claude/`) 또는 프로젝트 로컬(`.claude/`)
2. **커밋 전략** — Step마다, Phase마다, 또는 수동
3. **실행 모드** — hook 강제 또는 프롬프트 가이드
4. **에이전트 모드** — Team(TeamCreate), Subagent(Agent tool), Single(직접 수행)

## Usage

```
/dev-bounce 로그인 API에 rate limiting 추가해줘
```

그게 전부. 나머지는 자동:

```
Phase 0  인텐트 판별 (질문 vs 개발)
Phase 1  계획 수립 → EnterPlanMode → 사용자 승인
         ↓ accept
Phase 2  SIMPLE: 직접 개발 + TC 검증
Phase 3  NORMAL: Dev Team 스폰 → TDD 루프
Phase 4  NORMAL: 3라운드 통합 검증
```

## How It Works

### Hook Architecture

| Hook | Event | Role |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit) | 계획 미승인 시 코드 수정 차단 |
| **bash-gate.sh** | PreToolUse (Bash) | Bash를 통한 파일 쓰기 우회 차단 |
| **bash-audit.sh** | PostToolUse (Bash) | git diff로 무단 변경 감지 + 자동 복원 |
| **completion-gate.sh** | Stop | 검증 미완료 시 세션 종료 차단 |
| **doc-reminder.sh** | PostToolUse (Write/Edit) | TC/문서 작성 알림 |

### 2-Layer Bash Defense

```
Layer 1 (PreToolUse)     Layer 2 (PostToolUse)
┌─────────────────┐     ┌──────────────────────┐
│  bash-gate.sh   │     │   bash-audit.sh      │
│  쓰기 패턴 감지  │     │  git diff 스냅샷 비교  │
│  → 사전 차단     │     │  → 무단 변경 자동 복원  │
└─────────────────┘     └──────────────────────┘
```

Write/Edit은 plan-gate가 차단. Bash `echo > file`은 bash-gate가 차단. bash-gate를 우회해도 bash-audit가 복원.

### Complexity Modes

| | SIMPLE | NORMAL |
|---|---|---|
| **기준** | 변경 3파일 이하, 50줄 이하 | 4파일 이상 또는 신규 모듈 |
| **팀** | Main Claude 단독 | Lead + Dev + QA |
| **검증** | TC 통과 후 완료 | 3라운드 통합 검증 |

## Configuration

```bash
bash install.sh --config   # 설정 변경
```

| 설정 | 옵션 | 기본값 |
|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` |
| `agent_mode` | `team` · `subagent` · `single` | `team` |

## Tests

750건 이상의 e2e 테스트:

```bash
bash tests/e2e-full.sh       # 설치/업데이트/삭제 (74건)
bash tests/e2e-hooks.sh      # hook 동작 (123건)
bash tests/e2e-modes.sh      # 모드별 동작 (106건)
bash tests/e2e-install.sh    # 설치 시나리오 (130건)
bash tests/test-plan-gate.sh # plan-gate 단위 (25건)
bash tests/test-bash-gate.sh # bash-gate 단위 (33건)
```

## Update

```
/update-bouncer
```

또는 세션 시작 시 자동 체크 (24시간 throttle).

## Uninstall

```bash
bash uninstall.sh
```

hook, agent, skill, 설정을 제거한다. `.ai-bouncer-tasks/` 작업 문서는 보존.

## License

MIT

---

<p align="center">
  Built for <a href="https://claude.com/claude-code">Claude Code</a> by <a href="https://github.com/kangraemin">@kangraemin</a>
</p>
</div>
