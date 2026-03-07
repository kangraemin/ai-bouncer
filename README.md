# ai-bouncer

> A Claude Code workflow enforcement toolkit that prevents unplanned code changes and ensures every implementation is planned, tested, and verified.

---

## What is it?

**ai-bouncer** forces Claude Code to follow a structured development workflow — from intent detection to verified completion. It blocks code edits without an approved plan, enforces TDD at every step, and uses hook-based enforcement that cannot be bypassed.

Complexity determines the mode:

```
SIMPLE (1 기능)
  Request → Intent → Plan → Approval → Dev → Test → Done

NORMAL (복잡 작업)
  Request → Intent → Planning Team + Q&A → Plan Approval
    → Dev Team (Phase/Step TDD) → 3× Consecutive Verification → Done
```

---

## Why?

Claude Code is powerful but unstructured by default. Without guardrails, it:
- Jumps straight to coding without fully understanding requirements
- Skips tests or writes them after the fact
- Declares "done" before verifying all planned features are implemented
- Loses context mid-session and silently resumes from a stale state

ai-bouncer fixes this by enforcing a document-driven workflow where every agent is stateless and reads its context from files — making the process resilient to context window compression.

---

## How it works

### 2-Mode Workflow

#### Mode Selection (Phase 0)

The `intent` agent classifies the request (general / insufficient / dev task). Dev requests proceed to complexity assessment:

| Criteria | SIMPLE | NORMAL |
|----------|--------|--------|
| Scope | Single feature/bug/config | Multiple modules |
| Direction | Clear | Needs design discussion |
| Tests | Existing tests sufficient | New test cases needed |

#### SIMPLE Mode

Main Claude handles everything directly — no team spawn, no phase/step structure:

1. **Plan** — Explore code, write `plan.md`, get approval
2. **TC + Develop** — Write test cases in `tests.md` if applicable (`[TC:스킵]` if not), then implement
3. **Verify** — Run tests, lightweight plan-vs-diff check, done

#### NORMAL Mode

**Phase 1 — Planning Team**
A 3-agent team (`planner-lead`, `planner-dev`, `planner-qa`) collaborates to build a high-level plan via a Q&A loop — running inside **plan mode** so the user gets a structured review UI:
- `planner-lead` drives the loop and asks clarifying questions
- `planner-dev` contributes technical feasibility and risk analysis
- `planner-qa` contributes testability and edge case analysis
- The loop continues until 3 consecutive rounds produce **no new questions**

**Phase 2 — Plan Approval**
The finalized plan is presented via `ExitPlanMode`. Development is gated behind explicit approval. Revision requests re-enter plan mode automatically.

**Phase 3 — Development**
The `lead` agent determines team size based on **feature count**:

| Team | Criteria | Composition |
|------|----------|-------------|
| `solo` | Single feature | Lead does Dev+QA |
| `duo` | 2–5 features | Lead + Dev |
| `team` | 6+ features or parallelizable | Lead + Dev + QA |

Then drives a strict TDD loop per step:
1. QA defines test cases → `step-M.md`
2. Dev implements minimum code → `step-M.md`
3. QA runs tests → records results
4. Repeat until all steps pass

**Phase 4 — Verification**
The `verifier` agent runs an unlimited loop until 3 *consecutive* clean passes, each from a different perspective:
- **Round 1 — 기능 충실도**: plan.md compliance, doc completeness, feature coverage
- **Round 2 — 코드 품질**: code review, bugs, edge cases, naming/style
- **Round 3 — 통합 & 회귀**: full test suite, cross-file interactions, regression check
- **Any failure resets `rounds_passed` to 0** and restarts from Round 1

---

## Installation

```bash
bash <(curl -sL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

Choose global (`~/.claude/`) or local (`.claude/`) scope during installation.

### Update

```bash
bash install.sh --update
```

Or use `update.sh` from the repo root for development:

```bash
bash update.sh
```

### Uninstall

```bash
bash uninstall.sh
```

Or via install.sh (backward compatible):

```bash
bash install.sh --uninstall
```

Uninstall reads the manifest to remove exactly the files it installed, leaves your backups intact, and removes hook entries from `settings.json` and the injected rule block from `CLAUDE.md`.

---

## Usage

Once installed, start any development task with:

```
/dev-bounce <your request>
```

Example:

```
/dev-bounce implement user authentication with JWT
```

### Reconfigure commit strategy

```bash
bash install.sh --config
```

---

## Document-Driven Architecture

All state lives in files. Agents are stateless and reconstruct context by reading docs at the start of every turn — making the workflow resilient to Claude's context window being compressed or reset.

### Per-task directory structure

Tasks are organized by date under `docs/YYYY-MM-DD/`:

```
docs/
└── 2026-03-07/
    └── <task-name>/
        ├── .active                   # session marker (contains session_id)
        ├── plan.md                   # high-level plan (written by planner-lead)
        ├── state.json                # workflow state for this task
        ├── phase-1-<feature>/
        │   ├── phase.md              # scope and completion criteria
        │   ├── step-1.md             # TC + implementation + test results
        │   └── step-2.md
        ├── phase-2-<feature>/
        │   ├── phase.md
        │   └── step-1.md
        └── verifications/
            ├── round-1.md
            ├── round-2.md
            └── round-3.md
```

Session isolation — each task has its own `.active` file:

```
docs/
└── 2026-03-07/
    ├── user-auth/
    │   ├── .active           # session A
    │   ├── plan.md
    │   └── ...
    └── profile-page/
        ├── .active           # session B
        ├── plan.md
        └── ...
```

**Worktree exception**: When running in a git worktree, docs are stored in `~/.claude/ai-bouncer/sessions/<repo>/docs/` and copied to the main repo on completion.

### state.json schema

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

### Context recovery

If a session is interrupted or the context window is compressed:

1. `/dev-bounce` scans `docs/YYYY-MM-DD/<task>/.active` files to find the active task for this session
2. Reads `state.json` to determine `workflow_phase`
3. Resumes from the correct phase — planning, development, or verification
4. Stale tasks (other session's unapproved planning tasks) are auto-cleaned

---

## Enforcement Hooks

Five hooks are registered automatically into `settings.json`:

| Hook | Trigger | Behavior |
|---|---|---|
| `plan-gate.sh` | `PreToolUse` (Write/Edit) | Blocks code edits during planning or before TCs are defined |
| `bash-gate.sh` | `PreToolUse` (Bash) | Blocks Bash write patterns (`>`, `tee`, `sed -i`, `cp`, etc.) during planning |
| `bash-audit.sh` | `PostToolUse` (Bash) | Detects unauthorized file changes via `git diff` and auto-reverts |
| `doc-reminder.sh` | `PostToolUse` (Write/Edit) | Warns if a step doc hasn't been updated after a code change |
| `completion-gate.sh` | `Stop` | Blocks response completion if verification hasn't reached 3 consecutive passes |

**2-layer Bash defense**: `bash-gate.sh` blocks write patterns pre-execution, while `bash-audit.sh` catches anything that slips through by checking `git diff` post-execution and auto-reverting unauthorized changes. Bash-based gate bypass is fully blocked.

---

## Agents

| Agent | Phase | Role |
|---|---|---|
| `intent` | 0 | Classify request: general / insufficient / dev task |
| `planner-lead` | 1 | Lead the Q&A loop, finalize and write `plan.md` |
| `planner-dev` | 1 | Contribute technical feasibility and risk analysis |
| `planner-qa` | 1 | Contribute testability and edge case analysis |
| `lead` | 3 | Determine team size, decompose plan into phases and steps |
| `dev` | 3 | Implement code, update step docs |
| `qa` | 3 | Write TCs before implementation, run tests, record results |
| `verifier` | 4 | Verify plan vs implementation, run regression tests, manage 3× loop |

---

## Installation Options

| Prompt | Options |
|---|---|
| Scope | `1) global (~/.claude/)` · `2) local (.claude/)` |
| Commit strategy | `1) per-step` · `2) per-phase` · `3) none` |
| Track `docs/` in git | `y / n` |

Install also injects a rule into your `CLAUDE.md` so Claude automatically uses `/dev-bounce` for any coding task — even without an explicit `/dev-bounce` invocation.

---

## Project Structure

```
agents/
  intent.md          planner-lead.md    planner-dev.md
  planner-qa.md      lead.md            dev.md
  qa.md              verifier.md

skills/
  dev-bounce/
    SKILL.md         (/dev-bounce skill — full flow orchestration)

hooks/
  plan-gate.sh       bash-gate.sh       bash-audit.sh
  doc-reminder.sh    completion-gate.sh
  lib/
    resolve-task.sh  (shared task resolution library)

tests/
  test-plan-gate.sh  test-bash-gate.sh
  test-bash-audit.sh test-completion-gate.sh
  e2e-skill.sh

install.sh           (install/update/config)
uninstall.sh         (standalone uninstall)
update.sh            (dev-time sync to ~/.claude/)
```

---

## License

MIT
