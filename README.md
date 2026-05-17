<div align="center">

# ai-bouncer

**Stop Claude Code from touching code without a plan.**

[![License](https://img.shields.io/github/license/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/kangraemin/ai-bouncer?style=for-the-badge)](https://github.com/kangraemin/ai-bouncer/stargazers)
[![Tests](https://img.shields.io/badge/tests-130%2B-brightgreen?style=for-the-badge)](#tests)

[Getting Started](#install) · [한국어](README.ko.md) · [Issues](https://github.com/kangraemin/ai-bouncer/issues)

</div>

---

## Why ai-bouncer?

Claude Code is powerful, but without guardrails it goes off-script. You ask for one bug fix and it refactors three files. You're still thinking about the plan and it's already writing code. You say "done" and it skips verification. Context compacts mid-task and it forgets where it was.

| Without ai-bouncer | With ai-bouncer |
|---|---|
| Claude edits files you didn't ask for | Every change requires an approved plan |
| Starts coding before you agree on the approach | Plan mode → user approval → then development |
| `echo > file` bypasses Write/Edit restrictions | bash-gate catches write patterns pre-execution |
| No verification, just "I'm done" | TDD-enforced: TC first, code second, verify third |
| Compact/clear wipes context, work is lost | All progress in `state.json` — resume from anywhere |
| Multiple sessions step on each other | Session isolation via `.active` file locking |

---

## Features

### Workflow Enforcement

- **plan-gate** — blocks all Write/Edit/MultiEdit calls until you approve a plan via `ExitPlanMode`. Also checks step-level TC presence, `## 실행출력` records, and phase doc structure before allowing the next step.
- **bash-gate** — detects file-write patterns (`>`, `>>`, `tee`, `sed -i`, `cat/echo/printf >`, python `open(...,'w')`, etc.) and blocks them pre-execution. Closes the "bypass Write via Bash" hole.
- **completion-gate** — prevents Claude from ending the turn while a task is in `development`/`verification` without `verifications/e2e-result.md` reaching `## 결론` → `통과`.
- **block-logger** — every gate rejection is logged for later review (evidence collection).

### File-Based State

All workflow state lives on disk, not in context. `state.json` + `phase/step.md` + `verifications/e2e-result.md` mean a compacted or crashed session resumes exactly where it left off — hooks read the files, not the model's memory.

### Agent Modes

`max_concurrent` (derived from `depends_on` via Kahn's algorithm) decides the mode automatically:

- **single** — Main Claude does TC → code → verify itself. Phase/step structure still enforced by hooks.
- **subagent** — `Agent` tool spawns Dev + QA sub-processes per phase. Used when independent phases can run in parallel.
- **team** — `TeamCreate` spawns a registered team (config default).

### Session Isolation

Each task gets `.ai-bouncer-tasks/YYYY-MM-DD/task-name/` with an `.active` lock file containing the session ID. Hooks check ownership — a second session can't interfere with the first, and stale locks are auto-cleaned on Stop.

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

The interactive wizard walks you through:

1. **Scope** — global (`~/.claude/`) or project-local (`.claude/`)
2. **Commit strategy** — per-step, per-phase, or none
3. **Enforcement** — `hooks` (blocking) or `prompt-only` (skill guidance, no hooks)
4. **Agent mode** — `team`, `subagent`, or `single`

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
Phase 0   Intent detection — question/explore → answer, dev request → proceed
Phase 1   EnterPlanMode → explore code → write plan.md → user approval
           ↓ accept
Phase 3   Phase/Step breakdown → depends_on analysis → phase_layers (Kahn)
           → mode resolved (single / subagent / team)
           → per-step TDD loop: TC → code → verify → commit
Phase 4   workflow_phase = verification → critical-reviewer 6-step review
           → e2e-result.md "## 결론 통과" required → done
```

### What gets blocked

```
❌  Write("src/app.ts")            → plan-gate: plan not approved
❌  Bash("echo 'x' > src/app.ts")  → bash-gate: bash file-write blocked
❌  Bash("python3 -c 'open(f,\"w\")')  → bash-gate: detects python file write
❌  [Turn ends during verify]      → completion-gate: verification not passed
✅  Write(".ai-bouncer-tasks/.../state.json")  → allowed (task mgmt file)
✅  Bash("git status")             → allowed (read-only)
✅  Bash("npm test")               → allowed (no write pattern)
```

---

## How It Works

### Hook Architecture

| Hook | Event | What it checks |
|---|---|---|
| **plan-gate.sh** | PreToolUse (Write/Edit/MultiEdit) | `plan_approved`, `plan.md` exists, prev step.md has ✅ + `## 실행출력`, phase.md sections, TC format, verification-phase file scope |
| **bash-gate.sh** | PreToolUse (Bash) | write-pattern detection (`>`, `tee`, `sed -i`, `cp`, python write…) + same gate checks for file-writing commands |
| **completion-gate.sh** | Stop | task not stuck in development/verification; `e2e-result.md` `## 결론` → `통과` before turn can end |
| **stop-active-cleanup.sh** | Stop | removes stale `.active` lock when `workflow_phase` is `done`/`cancelled` |
| **subagent-track.sh** | SubagentStart | registers spawned agents for session tracking |
| **subagent-cleanup.sh** | SubagentStop | cleans up agent registrations |

Shared helpers in `hooks/lib/`: `gate-checks.sh` (common validation), `resolve-task.sh` (task dir resolution), `block-logger.sh` (rejection logging). `stop-bouncer-compat.sh` exists for older-config compatibility (not in `hooks.json`).

### Task Directory Structure

```
.ai-bouncer-tasks/
└── 2026-05-18/
    └── add-rate-limiting/
        ├── .active                    # session lock (contains session_id)
        ├── state.json                 # workflow state machine
        ├── plan.md                    # approved plan
        ├── phase-1-auth/
        │   ├── phase.md               # 목표 / 기술 접근 / Steps
        │   ├── step-1.md              # TC table + 실행출력
        │   └── step-2.md
        ├── phase-2-api/
        │   └── ...
        └── verifications/
            └── e2e-result.md          # critical-reviewer 6-step result
```

### State Machine

```
planning ──accept──→ development ──all phases done──→ verification ──결론 통과──→ done
    │                     │                               │
    │ reject              │ blocking                      │ 실패
    ↓                     ↓                               ↓
 cancelled          escalate to user               back to development
```

### Parallel Execution

`depends_on` between phases is analyzed after doc generation. Independent phases (`depends_on: []`) land in the same `phase_layers` layer and run concurrently. `max_concurrent ≥ 2` auto-selects `subagent`/`team`; `= 1` stays `single`. No user input required.

---

## Configuration

```bash
bash install.sh --config   # change settings after install
```

| Setting | Options | Default | Description |
|---|---|---|---|
| `commit_strategy` | `per-step` · `per-phase` · `none` | `per-step` | When to auto-commit |
| `enforcement_mode` | `hooks` · `prompt-only` | `hooks` | Hook enforcement or prompt guidance only |
| `agent_mode` | `team` · `subagent` · `single` | `team` | Base mode (overridden to single when fully serial) |
| `docs_git_track` | `true` · `false` | `false` | Track `.ai-bouncer-tasks/` in git |

Config lives at `.claude/ai-bouncer/config.json` (project-local) or `~/.claude/ai-bouncer/config.json` (global).

---

## Architecture

```
ai-bouncer/
├── install.sh                 # Interactive installer (--ci, --config)
├── update.sh                  # File-level update with manifest diff
├── uninstall.sh               # Clean removal
├── hooks/
│   ├── hooks.json             # Hook manifest
│   ├── plan-gate.sh           # PreToolUse: Write/Edit gate
│   ├── bash-gate.sh           # PreToolUse: Bash gate
│   ├── completion-gate.sh     # Stop: verification gate
│   ├── stop-active-cleanup.sh # Stop: stale .active cleanup
│   ├── subagent-track.sh      # SubagentStart: agent registration
│   ├── subagent-cleanup.sh    # SubagentStop: agent cleanup
│   ├── stop-bouncer-compat.sh # legacy-config compat
│   └── lib/
│       ├── gate-checks.sh     # shared gate validation
│       ├── resolve-task.sh    # task directory resolution
│       └── block-logger.sh    # rejection event logging
├── agents/
│   ├── intent.md              # Intent classifier
│   ├── lead.md                # Lead orchestrator
│   ├── dev.md                 # Developer agent
│   ├── qa.md                  # QA agent
│   ├── e2e-writer.md          # E2E test author
│   └── guides/tc-guide.md     # TC writing guide
├── skills/
│   ├── dev-bounce/SKILL.md    # Main workflow skill
│   ├── update-bouncer/SKILL.md
│   └── bouncer-status/SKILL.md
├── scripts/
│   └── bouncer-update-check.sh  # SessionStart auto-update (24h throttle)
└── tests/                     # 130+ e2e/unit tests (8 files)
```

---

## Tests

130+ tests across 8 files. Each creates an isolated temp environment with a fake `$HOME` — nothing touches your real setup.

```bash
bash tests/test-plan-gate.sh            # plan-gate unit (~23)
bash tests/test-bash-gate.sh            # bash-gate unit (~14)
bash tests/test-completion-gate.sh      # completion-gate unit (~31)
bash tests/test-block-logger.sh         # rejection logger (~10)
bash tests/test-phase-layers.sh         # Kahn layer computation (~5)
bash tests/test-delegated-team-bypass.sh # delegated agent allow path (~4)
bash tests/test-e2e-workflow.sh         # workflow state transitions (~33)
bash tests/e2e-install.sh               # install/update/uninstall lifecycle (~11)
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

Each `/dev-bounce` call creates a task directory with an `.active` file containing the session ID. Hooks check ownership — if another session tries to modify files, it's blocked. When a task completes, `.active` is removed (and stale locks are auto-cleaned on Stop).
</details>

<details>
<summary><strong>How is the agent mode chosen?</strong></summary>

It's automatic. After phase/step docs are generated, `depends_on` is analyzed and `phase_layers` computed via Kahn's algorithm. If the max concurrent phase count is 1, it runs `single`; if ≥ 2, it uses the configured `team`/`subagent` mode. You never pick it manually.
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
3. Run the test suite (e.g. `bash tests/test-plan-gate.sh`)
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
