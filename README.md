# ai-bouncer

> A Claude Code workflow enforcement toolkit that prevents unplanned code changes and ensures every implementation is planned, tested, and verified.

[![한국어](https://img.shields.io/badge/lang-한국어-blue)](README.ko.md)

---

## What is it?

**ai-bouncer** forces Claude Code to follow a structured development workflow — from intent detection to verified completion. It blocks code edits without an approved plan, enforces TDD at every step, and uses hook-based enforcement that cannot be bypassed.

Complexity determines the mode:

```
SIMPLE (single feature/bug)
  Request → Intent → Plan → Approval → Dev → Verify → Done

NORMAL (complex task)
  Request → Intent → Plan → Approval
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

## Benchmark

Same app (YouTube subtitle extraction → AI summary → chat) built from scratch, 5 times each:

| | with dev-bounce | without |
|---|---|---|
| **API contract pass rate** | **100%** (5/5) | 60% (3/5) |
| **Weighted score** | **8.27** / 10 | 5.53 / 10 |
| Avg time | 662s (11 min) | 901s (15 min) |
| Avg cost | $7.0 | $5.8 |
| Timeouts | 0 | 1 |

Key findings:

- **API consistency is the biggest gap** — without dev-bounce, frontend/backend field names diverge 40% of the time
- **27% faster, more stable** — gate system prevents wasted cycles; time variance is much smaller
- **Design patterns are more mature without** — but broken APIs make that irrelevant
- **17% more expensive** — verification steps consume extra tokens

> Full experiment report: [youtube-helper repo](https://github.com/kangraemin/youtube-helper) | Stack: Flutter + FastAPI + Gemini

---

## How it works

### 2-Mode Workflow

#### Mode Selection (Phase 0)

The `intent` agent classifies the request (general / insufficient / dev task). Dev requests proceed to complexity assessment:

| Criteria | SIMPLE | NORMAL |
|----------|--------|--------|
| Changed files | 1–3 expected | 4+ or uncertain |
| Scope | Single feature/bug/config | Multiple modules |
| Direction | Clear | Needs design discussion |
| Tests | Existing tests sufficient | New test cases needed |

#### SIMPLE Mode

Main Claude handles everything directly — no team spawn, no phase/step structure:

1. **Plan** — Explore code, write `plan.md` with Before/After snippets, get approval
2. **TC + Develop** — Write test cases in `tests.md` (table + execution output format, mandatory), implement, record actual command output as evidence
3. **Verify** — Run tests, lightweight plan-vs-diff check, done

#### NORMAL Mode

**Phase 1 — Planning**
Main Claude directly explores the codebase, enters plan mode, writes a detailed `plan.md` with Before/After snippets, and presents it for approval.

**Phase 2 — Plan Approval**
The finalized plan is presented via `ExitPlanMode`. Development is gated behind explicit approval. Revision requests re-enter plan mode automatically.

**Phase 3 — Development**

Development execution depends on the configured `agent_mode`:

| Mode | Phase 3 (Dev) | Phase 4 (Verify) |
|------|--------------|-------------------|
| `team` | TeamCreate → Lead + Dev + QA agents | Verifier agent via TeamCreate |
| `subagent` | Agent tool → Lead + Dev + QA agents | Verifier via Agent tool |
| `single` | Main Claude directly (phase/step structure maintained for hook enforcement) | Main Claude runs 3× verification directly |

The `lead` agent (or Main Claude in single mode) determines team size based on **feature count**:

| Team | Criteria | Composition |
|------|----------|-------------|
| `duo` | 2–5 features | Lead + Dev (Lead doubles as QA) |
| `team` | 6+ features or parallelizable | Lead + Dev + QA |

Then drives a strict TDD loop per step:
1. QA defines test cases in `step-M.md` (table format with expected results)
2. Dev implements minimum code to pass TCs
3. QA runs tests → records actual execution output as evidence in `step-M.md`
4. Repeat until all steps pass — steps without execution output evidence are blocked by hooks

**Phase 4 — Verification**
The `verifier` agent runs an unlimited loop until 3 *consecutive* clean passes, each from a different perspective:
- **Round 1 — Feature fidelity**: plan.md compliance, doc completeness, feature coverage
- **Round 2 — Code quality**: code review, bugs, edge cases, naming/style
- **Round 3 — Integration & regression**: full test suite, cross-file interactions, regression check
- **Any failure resets `rounds_passed` to 0** and restarts from Round 1

---

## Installation

Run from your project root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

### Update

```bash
bash update.sh
```

### Uninstall

```bash
bash uninstall.sh
```

Or via install.sh:

```bash
bash install.sh --uninstall
```

Uninstall reads the manifest to remove exactly the files it installed, removes hook entries from `settings.json` and the injected rule block from `CLAUDE.md`.

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

### Reconfigure

```bash
bash install.sh --config
```

---

## Installation Options

| Prompt | Options |
|---|---|
| Track `docs/` in git | `y / n` |
| Commit strategy | `1) per-step` · `2) per-phase` · `3) none` |
| Execution mode | `1) hooks` (enforced) · `2) prompt-only` (guidance only) |
| Agent mode | `1) team` (TeamCreate) · `2) subagent` (Agent tool) · `3) single` (Main Claude only) |

Install injects a rule into your project's `.claude/CLAUDE.md` so Claude automatically uses `/dev-bounce` for any coding task.

---

## Document-Driven Architecture

All state lives in files. Agents are stateless and reconstruct context by reading docs at the start of every turn — making the workflow resilient to Claude's context window being compressed or reset.

### Per-task directory structure

Tasks are organized by date under `docs/YYYY-MM-DD/`:

```
docs/
└── 2026-03-07/
    └── <task-name>/
        ├── .active                   # session marker (hook auto-claims session_id)
        ├── plan.md                   # plan with Before/After snippets
        ├── state.json                # workflow state for this task
        ├── phase-1-<feature>/
        │   ├── phase.md              # scope and completion criteria
        │   ├── step-1.md             # TC table + implementation + execution output evidence
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
  "active_file": "docs/2026-03-07/user-auth/.active"
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

Nine hooks registered automatically into `settings.json`, grouped by lifecycle event:

**PreToolUse** — `plan-gate` (Edit/Write) · `bash-gate` (Bash)
→ any check fails → ⛔ blocks tool execution

Runs before every Edit/Write/Bash — if any gate condition isn't met, the tool call is blocked before it executes.

| Check | Why |
|---|---|
| Plan approved? | No editing without an approved plan |
| TC defined for this step? | No implementation without test criteria |
| Previous step tests passing? | No moving forward from a broken state |
| Team assembled? _(NORMAL + team mode only)_ | No dev phase without agents in place |
| Committing with tests failing? _(Bash only)_ | No committing broken code |

**PostToolUse** — `doc-reminder` (Edit/Write)
→ step doc missing → ⛔ blocks

PreToolUse would block the doc write itself — so PostToolUse checks instead: code changed but no step doc → blocked.

| Check | Why |
|---|---|
| Step doc exists? | Code changes without docs can't be traced |

**PostToolUse** — `bash-audit` (Bash)
→ unauthorized change detected → 🔄 auto-reverts (no block)

PreToolUse (bash-gate) blocks obvious write patterns; PostToolUse (bash-audit) diffs git before/after and reverts anything that snuck through.

| Check | Why |
|---|---|
| Files changed without passing PreToolUse? | 2nd layer to catch any PreToolUse bypass |

**SubagentStart / SubagentStop** — `subagent-track` · `subagent-cleanup`
→ no block — tracks only

Parent already passed all checks — sub-agents skip PreToolUse/PostToolUse to avoid false positives. Permissions revoked on Stop so they can't be reused.

**Stop** — `completion-gate`
→ verification incomplete → ⛔ blocks response

Runs when Claude tries to end a turn — blocks the response until 3 consecutive verification rounds pass.

| Check | Why |
|---|---|
| 3 consecutive verification passes? | Prevents closing out before work is fully done |

**Stop** — `stop-active-cleanup`
→ no block — cleanup only

Runs on every Stop — cleans up lock files. No blocking.

| Action | Why |
|---|---|
| Auto-delete lock file on completion | Next task shouldn't be blocked by a stale lock |

**SessionStart** — `update-check`
→ no block — version check only

Runs when Claude Code starts a session — checks for available updates silently.

| Action | Why |
|---|---|
| Check for newer version | Prompt user to update without blocking work |

> `stop-bouncer-compat` is injected into existing user-defined Stop hooks to suppress false-positive uncommitted-file warnings during team tasks — it is not a separately registered hook.


---

## Agents

| Agent | Phase | Role |
|---|---|---|
| `intent` | 0 | Classify request: general / insufficient / dev task |
| `lead` | 3 | Determine team size, decompose plan into phases and steps, orchestrate Dev/QA |
| `dev` | 3 | Implement code, update step docs |
| `qa` | 3 | Write TCs before implementation, run tests, record results |
| `verifier` | 4 | Verify plan vs implementation, run regression tests, manage 3× loop |

Supporting files:
- `agents/guides/tc-guide.md` — test case writing guide for QA

---

## Project Structure

```
agents/
  intent.md            lead.md              dev.md
  qa.md                verifier.md
  guides/
    tc-guide.md

skills/
  dev-bounce/
    SKILL.md           (/dev-bounce skill — full flow orchestration)

hooks/
  plan-gate.sh         bash-gate.sh         bash-audit.sh
  doc-reminder.sh      completion-gate.sh   stop-bouncer-compat.sh
  subagent-track.sh    subagent-cleanup.sh
  hooks.json           (hook metadata manifest)
  lib/
    resolve-task.sh    (shared task resolution library)

tests/
  e2e-full.sh          (full lifecycle: install → hook → update → uninstall)
  e2e-hooks.sh         (hook logic tests — 85 assertions)
  e2e-install.sh       (install/uninstall tests)
  e2e-modes.sh         (agent mode combination tests)
  e2e-workflow.sh      (workflow integration tests)
  e2e-restore.sh       (context restore tests)
  e2e-skill.sh         (skill tests)
  test-bash-audit.sh   (bash-audit unit tests)
  test-bash-gate.sh    (bash-gate unit tests)
  test-completion-gate.sh (completion-gate unit tests)
  test-plan-gate.sh    (plan-gate unit tests)

install.sh             (install/update/config)
uninstall.sh           (standalone uninstall)
update.sh              (quick update shortcut)
```

---

## License

MIT
