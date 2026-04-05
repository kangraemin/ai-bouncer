<div align="center">

# ai-bouncer

**Stop Claude Code from touching code without a plan.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-750%2B-brightgreen?style=for-the-badge)](#tests)

[Getting Started](#install) · [한국어](README.ko.md) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

## Why ai-bouncer?

Claude Code is powerful, but without guardrails it tends to go off-script. You ask for one bug fix and it refactors three files. You're still thinking about the plan and it's already writing code. You say "done" and it skips verification.

| Without ai-bouncer | With ai-bouncer |
|---|---|
| Claude edits files you didn't ask for | Every change requires an approved plan |
| Starts coding before you agree on the approach | Plan mode → user approval → then development |
| `echo > file` bypasses Write/Edit restrictions | 2-layer Bash defense catches all file writes |
| No verification, just "I'm done" | TDD-enforced: TC first, code second, verify third |
| Multiple sessions step on each other | Session isolation via `.active` file locking |

---

## Features

### Workflow Enforcement

- **Plan-gate** — blocks all Write/Edit calls until you approve a plan via `ExitPlanMode`
- **Bash-gate** — detects 15+ write patterns (`>`, `tee`, `sed -i`, `cp`, `curl -o`, etc.) and blocks them pre-execution
- **Bash-audit** — post-execution git diff snapshot comparison catches anything bash-gate misses, auto-reverts unauthorized changes
- **Completion-gate** — prevents Claude from ending the conversation before verification passes

### Development Modes

- **SIMPLE** — for small changes (3 files, 50 lines). Main Claude handles everything: plan, code, test, done.
- **NORMAL** — for larger work. Spawns a Dev Team (Lead + Dev + QA) with TDD loop per step, 3-round verification at the end.

### Multi-Agent Orchestration

- **Team mode** — `TeamCreate` spawns a real team. Lead orchestrates, Dev codes, QA validates.
- **Subagent mode** — `Agent` tool spawns lightweight sub-processes. Same workflow, less overhead.
- **Single mode** — Main Claude does everything. Phase/step structure still enforced by hooks.

### Session Isolation

Each task gets its own directory (`.ai-bouncer-tasks/YYYY-MM-DD/task-name/`) with an `.active` lock file containing the session ID. Hooks check ownership — a second session can't interfere with the first.

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

The interactive wizard walks you through:

1. **Scope** — global (`~/.claude/`) or project-local (`.claude/`)
2. **Commit strategy** — per-step, per-phase, or manual
3. **Enforcement** — hook-enforced or prompt-only (no hooks, just skill guidance)
4. **Agent mode** — Team, Subagent, or Single

For CI/non-interactive environments:

```bash
bash install.sh --ci
```

---

## Usage

```
/dev-bounce Add rate limiting to the login API
```

That's it. The rest is automatic:

```
Phase 0   Intent detection — question → answer, dev request → proceed
Phase 1   Plan → EnterPlanMode → explore code → write plan → user approval
           ↓ accept
Phase 1-B Complexity check → SIMPLE or NORMAL
           ↓
Phase 2   SIMPLE: TC → code → verify → commit → done
Phase 3   NORMAL: Lead spawns → phase/step breakdown → TDD loop
Phase 4   NORMAL: 3-round integration verification → done
```

### What gets blocked

```
❌  Write("src/app.ts")              → plan-gate: "계획이 승인되지 않았습니다"
❌  Bash("echo 'x' > src/app.ts")   → bash-gate: "Bash를 통한 파일 쓰기가 차단되었습니다"
❌  Bash("python3 -c 'open(f,w)')   → bash-gate: detects python file write
❌  [Session ends during verify]     → completion-gate: "검증이 완료되지 않았습니다"
✅  Write("state.json")             → allowed (task management file)
✅  Bash("git status")              → allowed (read-only)
✅  Bash("npm test")                → allowed (no write pattern)
```

---

## How It Works

### Hook Architecture

| Hook | Event | What it checks |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit) | `plan_approved`, `plan.md` exists, team config, step TC, phase.md sections |
| **bash-gate.sh** | PreToolUse (Bash) | Write pattern detection, same checks as plan-gate for file-writing commands |
| **bash-audit.sh** | PostToolUse (Bash) | git diff pre/post snapshot, auto-reverts unauthorized changes |
| **completion-gate.sh** | Stop | 3x `round-*.md` with "통과" required before session can end |
| **doc-reminder.sh** | PostToolUse (Write/Edit) | Reminds to update TC/docs after code changes |
| **subagent-track.sh** | SubagentStart | Registers spawned agents for session tracking |
| **subagent-cleanup.sh** | SubagentStop | Cleans up agent registrations |

### 2-Layer Bash Defense

```
                    Bash("echo 'x' > src/app.ts")
                              │
                    ┌─────────▼──────────┐
        Layer 1     │    bash-gate.sh    │   PreToolUse
                    │  pattern detection │
                    │  15+ write patterns│
                    └──────┬─────────────┘
                           │ blocked → ⛔ REJECT
                           │ missed  ↓
                    ┌──────▼─────────────┐
        Layer 2     │   bash-audit.sh    │   PostToolUse
                    │  git diff snapshot │
                    │  before vs after   │
                    └──────┬─────────────┘
                           │ changed → 🔄 AUTO-REVERT
                           │ clean   → ✅ PASS
```

### Task Directory Structure

```
.ai-bouncer-tasks/
└── 2026-04-04/
    └── add-rate-limiting/
        ├── .active                    # session lock (contains session_id)
        ├── state.json                 # workflow state machine
        ├── plan.md                    # approved plan
        ├── tests.md                   # SIMPLE mode TCs
        ├── phase-1-auth/              # NORMAL mode
        │   ├── phase.md               # goals, scope, steps
        │   ├── step-1.md              # TC + implementation + results
        │   └── step-2.md
        └── verifications/             # NORMAL mode
            ├── round-1.md
            ├── round-2.md
            └── round-3.md
```

### State Machine

```
planning ──accept──→ development ──all steps done──→ verification ──3 rounds pass──→ done
    │                     │                              │
    │ reject              │ blocking                     │ failure
    ↓                     ↓                              ↓
 cancelled          escalate to user              back to development
```

---

## Configuration

```bash
bash install.sh --config   # change settings after install
```

| Setting | Options | Default | Description |
|---|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` | When to auto-commit |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` | Hook enforcement or prompt guidance only |
| `agent_mode` | `team` · `subagent` · `single` | `team` | How agents are spawned |
| `docs_git_track` | `true` · `false` | `false` | Track `.ai-bouncer-tasks/` in git |

---

## Architecture

```
ai-bouncer/
├── install.sh                 # Interactive installer (supports --ci, --config)
├── update.sh                  # File-level update with manifest diff
├── uninstall.sh               # Clean removal
├── hooks/
│   ├── hooks.json             # Hook manifest (dynamic install)
│   ├── plan-gate.sh           # PreToolUse: Write/Edit gate
│   ├── bash-gate.sh           # PreToolUse: Bash gate
│   ├── bash-audit.sh          # PostToolUse: Bash audit + revert
│   ├── completion-gate.sh     # Stop: verification gate
│   ├── doc-reminder.sh        # PostToolUse: doc nudge
│   ├── subagent-track.sh      # SubagentStart: agent registration
│   ├── subagent-cleanup.sh    # SubagentStop: agent cleanup
│   ├── stop-active-cleanup.sh # Stop: stale .active cleanup
│   └── lib/
│       └── resolve-task.sh    # Shared: task directory resolution
├── agents/
│   ├── intent.md              # Intent classifier
│   ├── lead.md                # Lead orchestrator
│   ├── dev.md                 # Developer agent
│   ├── qa.md                  # QA agent
│   └── verifier.md            # Integration verifier
├── skills/
│   ├── dev-bounce/SKILL.md    # Main workflow skill
│   ├── update-bouncer/SKILL.md
│   └── bouncer-status/SKILL.md
├── scripts/
│   └── bouncer-update-check.sh        # SessionStart auto-update (24h throttle)
└── tests/                     # 750+ e2e tests
```

---

## Tests

750+ tests across 13 files. All tests create isolated temp environments with fake `$HOME` — nothing touches your real setup.

```bash
bash tests/e2e-full.sh           # install/update/uninstall lifecycle (74)
bash tests/e2e-hooks.sh          # hook behavior — all modes (123)
bash tests/e2e-modes.sh          # enforcement/agent mode combos (106)
bash tests/e2e-install.sh        # install scenarios + migration (130)
bash tests/e2e-workflow.sh       # workflow state transitions (105)
bash tests/e2e-isolation.sh      # multi-session isolation (47)
bash tests/e2e-recovery.sh       # crash recovery + edge cases (73)
bash tests/e2e-restore.sh        # context restore logic (17)
bash tests/e2e-skill.sh          # SKILL.md path logic (8)
bash tests/test-plan-gate.sh     # plan-gate unit tests (25)
bash tests/test-bash-gate.sh     # bash-gate unit tests (33)
bash tests/test-completion-gate.sh # completion-gate unit tests (11)
bash tests/test-bash-audit.sh    # bash-audit unit tests (10)
```

---

## FAQ

<details>
<summary><strong>Does it work with prompt-only mode (no hooks)?</strong></summary>

Yes. Set `enforcement_mode: prompt-only` during install. The workflow is guided by SKILL.md prompts instead of hooks. Claude follows the plan→approve→develop→verify flow voluntarily. Less strict, but works when hooks aren't desired.
</details>

<details>
<summary><strong>Can I use it on existing projects?</strong></summary>

Yes. Run the installer from your project directory and select local scope. It only adds files under `.claude/` and `.ai-bouncer-tasks/` — no existing files are modified except `.gitignore` (managed block).
</details>

<details>
<summary><strong>What if a hook blocks something it shouldn't?</strong></summary>

Report the issue. As a workaround, the `! command` prefix in Claude Code runs commands directly in your terminal, bypassing hooks. Or switch to `prompt-only` mode temporarily.
</details>

<details>
<summary><strong>How does multi-session work?</strong></summary>

Each `/dev-bounce` call creates a task directory with an `.active` file containing the session ID. Hooks check ownership — if another session tries to modify files, it's blocked. When a task completes, `.active` is removed.
</details>

<details>
<summary><strong>Does it support Claude Code teams (TeamCreate)?</strong></summary>

Yes, that's the default `team` mode. Lead orchestrates, Main Claude spawns Dev/QA. For lighter setups, use `subagent` (Agent tool) or `single` (no agents).
</details>

---

## Update

```
/update-bouncer
```

Or automatic check on `SessionStart` (24h throttle). Updates use manifest diffing — only changed files are overwritten.

## Uninstall

```bash
bash uninstall.sh
```

Removes hooks, agents, skills, and config from `settings.json`. Preserves `.ai-bouncer-tasks/` work documents.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run the test suite: `bash tests/e2e-full.sh`
4. Open a Pull Request

## License

MIT

---

<p align="center">
  Built for <a href="https://claude.com/claude-code">Claude Code</a> by <a href="https://github.com/kangraemin">@kangraemin</a>
  <br />
  <sub>If this saved your codebase from unauthorized edits, consider giving it a star.</sub>
</p>
</div>
