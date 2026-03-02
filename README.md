# ai-bouncer

> A Claude Code workflow enforcement toolkit that prevents unplanned code changes and ensures every implementation is planned, tested, and verified.

---

## What is it?

**ai-bouncer** forces Claude Code to follow a structured 5-phase development workflow — from intent detection to triple-verified completion. It blocks code edits without an approved plan, enforces TDD at every step, and requires 3 consecutive clean verification passes before marking work as done.

```
Request → Intent Check → Planning Team + Q&A → Plan Approval
  → Dev Team (Phase breakdown + TDD) → 3× Consecutive Verification → Done
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

### The 5-Phase Flow

**Phase 0 — Intent Detection**
The `intent` agent classifies the request: general conversation, insufficient information, or a development task. Non-dev requests are handled immediately; dev requests proceed to planning.

**Phase 1 — Planning Team**
A 3-agent team (`planner-lead`, `planner-dev`, `planner-qa`) collaborates to build a high-level plan via a Q&A loop — running inside **plan mode** so the user gets a structured review UI:
- `planner-lead` drives the loop and asks clarifying questions
- `planner-dev` contributes technical feasibility and risk analysis
- `planner-qa` contributes testability and edge case analysis
- The loop continues until 3 consecutive rounds produce **no new questions**
- Any user answer resets the streak to 0

**Phase 2 — Plan Approval**
The finalized plan is presented via `ExitPlanMode`. Development is gated behind explicit approval. Revision requests re-enter plan mode automatically.

**Phase 3 — Development**
The `lead` agent holistically determines team size (`solo` / `duo` / `team`), breaks the plan into numbered dev phases and atomic steps, then drives a strict TDD loop:
1. QA defines test cases first → writes `step-M.md` TC section
2. Dev implements minimum code → writes `step-M.md` implementation section
3. QA runs tests → writes results to `step-M.md`
4. Repeat until all steps pass

On step/phase completion, commits are made automatically according to the **commit strategy** configured at install time (`per-step`, `per-phase`, or `none`).

**Phase 4 — Verification**
The `verifier` agent runs an unlimited loop until 3 *consecutive* clean passes:
- Reads only from `docs/` files (never from conversation context)
- Checks every feature in `plan.md` is implemented
- Validates document completeness across all step files
- Re-runs the full test suite
- **Any failure resets `rounds_passed` to 0** — there is no maximum attempt count

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

### Uninstall

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

```
docs/
├── .active                       # name of the currently active task
└── <task-name>/
    ├── plan.md                   # high-level plan (written by planner-lead)
    ├── state.json                # workflow state for this task
    ├── phase-1-<feature>/
    │   ├── phase.md              # scope and completion criteria for this phase
    │   ├── step-1.md             # TC + implementation + test results
    │   └── step-2.md
    ├── phase-2-<feature>/
    │   ├── phase.md
    │   └── step-1.md
    └── verifications/
        ├── round-1.md
        └── round-2.md
```

Multiple tasks coexist without interference:

```
docs/
├── user-auth/
│   ├── plan.md
│   └── ...
└── profile-page/
    ├── plan.md
    └── ...
```

### state.json schema

```json
{
  "workflow_phase": "planning",
  "planning": {
    "no_question_streak": 0
  },
  "plan_approved": false,
  "current_dev_phase": 0,
  "current_step": 0,
  "dev_phases": {
    "1": {
      "name": "auth",
      "folder": "phase-1-auth",
      "steps": {
        "1": {
          "title": "JWT token generation",
          "test_defined": false,
          "passed": false,
          "doc_path": "docs/phase-1-auth/step-1.md"
        }
      }
    }
  },
  "verification": {
    "rounds_passed": 0
  }
}
```

### Context recovery

If a session is interrupted or the context window is compressed:

1. `/dev-bounce` reads `docs/.active` to find the active task
2. Reads `state.json` to determine `workflow_phase`
3. Resumes from the correct phase — planning, development, or verification
4. No work is lost

---

## Enforcement Hooks

Three hooks are registered automatically into `settings.json`:

| Hook | Trigger | Behavior |
|---|---|---|
| `plan-gate.sh` | `PreToolUse` (Write/Edit) | Blocks code edits during planning phase or before test cases are defined |
| `doc-reminder.sh` | `PostToolUse` (Write/Edit) | Warns if a step doc hasn't been updated after a code change |
| `completion-gate.sh` | `Stop` | Blocks response completion if verification phase hasn't reached 3 consecutive passes |

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

## Included Files

```
agents/
  intent.md          planner-lead.md    planner-dev.md
  planner-qa.md      lead.md            dev.md
  qa.md              verifier.md

commands/
  dev-bounce.md      (/dev-bounce skill — full flow orchestration)

hooks/
  plan-gate.sh       doc-reminder.sh    completion-gate.sh
```

---

## License

MIT
