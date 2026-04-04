<div align="center">

# ai-bouncer

**Stop Claude Code from touching code without a plan.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-750%2B-brightgreen?style=for-the-badge)](#tests)

[Getting Started](#install) · [한국어](README.ko.md) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

Claude Code is powerful, but it sometimes edits files you didn't ask for, starts coding without approval, or skips verification entirely.

ai-bouncer fixes this with **hook-enforced workflows**.

- **Plan → Approve → Develop → Verify** — no code changes without approval
- **2-layer Bash defense** — blocks Write/Edit and Bash file-write bypasses
- **TDD enforcement** — TC first, then code, step-level locking
- **Multi-session isolation** — parallel sessions on the same project don't interfere

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

The interactive wizard walks you through:

1. **Scope** — global (`~/.claude/`) or project-local (`.claude/`)
2. **Commit strategy** — per-step, per-phase, or manual
3. **Enforcement** — hook-enforced or prompt-only
4. **Agent mode** — Team (TeamCreate), Subagent (Agent tool), or Single

## Usage

```
/dev-bounce Add rate limiting to the login API
```

That's it. The rest is automatic:

```
Phase 0  Intent detection (question vs development)
Phase 1  Plan → EnterPlanMode → user approval
         ↓ accept
Phase 2  SIMPLE: direct development + TC verification
Phase 3  NORMAL: Dev Team spawn → TDD loop
Phase 4  NORMAL: 3-round integration verification
```

## How It Works

### Hook Architecture

| Hook | Event | Role |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit) | Block code changes without approved plan |
| **bash-gate.sh** | PreToolUse (Bash) | Block file writes via Bash bypass |
| **bash-audit.sh** | PostToolUse (Bash) | Detect + auto-revert unauthorized changes |
| **completion-gate.sh** | Stop | Block session end before verification |
| **doc-reminder.sh** | PostToolUse (Write/Edit) | Nudge TC/doc writing |

### 2-Layer Bash Defense

```
Layer 1 (PreToolUse)     Layer 2 (PostToolUse)
┌─────────────────┐     ┌──────────────────────┐
│  bash-gate.sh   │     │   bash-audit.sh      │
│  write pattern  │     │  git diff snapshot    │
│  detection      │     │  comparison           │
│  → pre-block    │     │  → auto-revert        │
└─────────────────┘     └──────────────────────┘
```

Write/Edit goes through plan-gate. Bash `echo > file` hits bash-gate. If bash-gate is bypassed, bash-audit reverts.

### Complexity Modes

| | SIMPLE | NORMAL |
|---|---|---|
| **Criteria** | 3 files or fewer, under 50 lines | 4+ files or new modules |
| **Team** | Main Claude solo | Lead + Dev + QA |
| **Verification** | TC pass → done | 3-round integration verification |

## Configuration

```bash
bash install.sh --config   # change settings
```

| Setting | Options | Default |
|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` |
| `agent_mode` | `team` · `subagent` · `single` | `team` |

## Tests

750+ e2e tests across 13 test files:

```bash
bash tests/e2e-full.sh       # install/update/uninstall (74)
bash tests/e2e-hooks.sh      # hook behavior (123)
bash tests/e2e-modes.sh      # mode-specific behavior (106)
bash tests/e2e-install.sh    # install scenarios (130)
bash tests/test-plan-gate.sh # plan-gate unit (25)
bash tests/test-bash-gate.sh # bash-gate unit (33)
```

## Update

```
/update-bouncer
```

Or automatic check on session start (24h throttle).

## Uninstall

```bash
bash uninstall.sh
```

Removes hooks, agents, skills, and config. Preserves `.ai-bouncer-tasks/` work documents.

## License

MIT

---

<p align="center">
  Built for <a href="https://claude.com/claude-code">Claude Code</a> by <a href="https://github.com/kangraemin">@kangraemin</a>
</p>
</div>
