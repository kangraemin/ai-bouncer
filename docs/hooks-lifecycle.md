# ai-bouncer Hook Lifecycle

How each hook fires across the Claude Code lifecycle.

[![한국어](https://img.shields.io/badge/lang-한국어-blue)](hooks-lifecycle.ko.md)

---

## Hooks by lifecycle event

### 🔴 PreToolUse — `plan-gate` (Edit/Write) · `bash-gate` (Bash)
→ any check fails → ⛔ blocks tool execution

| Check | Why |
|---|---|
| Plan approved? | No editing without an approved plan |
| TC defined for this step? | No implementation without test criteria |
| Previous step tests passing? | No moving forward from a broken state |
| Team assembled? _(NORMAL + team mode only)_ | No dev phase without agents in place |
| Committing with tests failing? _(Bash only)_ | No committing broken code |

### 🟡 PostToolUse — `doc-reminder` (Edit/Write)
→ step doc missing → ⛔ blocks

| Check | Why |
|---|---|
| Step doc exists? | Code changes without docs can't be traced |

### 🟡 PostToolUse — `bash-audit` (Bash)
→ unauthorized change detected → 🔄 auto-reverts (no block)

| Check | Why |
|---|---|
| Files changed without passing PreToolUse? | 2nd layer to catch any PreToolUse bypass |

### 🔵 SubagentStart / SubagentStop — `subagent-track` · `subagent-cleanup`
→ no block — tracks only

| Event | Action | Why |
|---|---|---|
| Sub-agent starts | Grant bypass | Parent already passed all checks — re-blocking would be a false positive |
| Sub-agent stops | Revoke bypass | Prevent other agents from reusing the exemption |

### 🟠 Stop — `completion-gate`
→ verification incomplete → ⛔ blocks response

| Check | Why |
|---|---|
| 3 consecutive verification passes? | Prevents closing out before work is fully done |

### 🟠 Stop — `stop-active-cleanup` · `stop-bouncer-compat`
→ no block — cleanup / skip only

| Action | Why |
|---|---|
| Auto-delete lock file on completion | Next task shouldn't be blocked by a stale lock |
| Suppress uncommitted-file warning during team tasks | Agents commit in parallel — warning would be a false positive |

---

## Lifecycle flow

```mermaid
sequenceDiagram
    actor U as 👤 User
    participant C as 🤖 Claude
    participant PRE as 🔴 PreToolUse
    participant T as 🛠 Tool
    participant POST as 🟡 PostToolUse
    participant SUB as 🔵 SubagentStart/Stop
    participant STP as 🟠 Stop

    U->>C: Message

    rect rgb(255, 220, 220)
        note over PRE: Edit/Write: no plan · no TC · prev step failing → block<br/>Bash: same + committing with tests failing → block
        C->>PRE: plan-gate / bash-gate
        PRE-->>C: ⛔ Block or ✅ Pass
    end

    C->>T: Execute tool
    T-->>C: Done

    rect rgb(255, 255, 200)
        note over POST: Edit/Write: step doc missing → block<br/>Bash: files changed without passing PreToolUse → auto-revert (2nd layer)
        C->>POST: doc-reminder / bash-audit
        POST-->>C: ⛔ Block or 🔄 Auto-revert
    end

    opt When spawning a sub-agent
        rect rgb(210, 230, 255)
            note over SUB: Parent already passed — skip checks for sub-agent<br/>Revoke on stop so other agents can't reuse it
            C->>SUB: subagent-track (start)
            SUB-->>C: subagent-cleanup (stop)
        end
    end

    rect rgb(255, 230, 200)
        note over STP: 3 consecutive passes? if not → block turn end (can't close out early)<br/>Auto-delete lock file on completion<br/>Suppress uncommitted-file warning during team tasks
        C->>STP: completion-gate etc.
        STP-->>C: ⛔ Block or ✅ Pass
    end

    C-->>U: Response
```
