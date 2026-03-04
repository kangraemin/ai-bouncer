# Phase 2 / Step 1: 설치된 파일 동기화

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n '/dev-bounce' ~/.claude/hooks/plan-gate.sh` | `/dev-bounce로` 존재 |
| TC-2 | `grep -n '"block"' ~/.claude/hooks/doc-reminder.sh` | `"block"` 존재 |
| TC-3 | `grep -n '/dev-bounce' ~/.claude/agents/lead.md` | `/dev-bounce로` 존재 |
| TC-4 | `grep -n 'dev-bounce skill' ~/.claude/agents/planner-lead.md` | 존재 |
| TC-5 | `grep -n 'ExitPlanMode 절대 금지' ~/.claude/skills/dev-bounce/SKILL.md` | 존재 |

## 구현 내용

소스에서 수정된 파일을 `~/.claude/` 설치 위치에 복사:
- `hooks/plan-gate.sh` → `~/.claude/hooks/plan-gate.sh`
- `hooks/doc-reminder.sh` → `~/.claude/hooks/doc-reminder.sh`
- `agents/lead.md` → `~/.claude/agents/lead.md`
- `agents/planner-lead.md` → `~/.claude/agents/planner-lead.md`
- `skills/dev-bounce/SKILL.md` → `~/.claude/skills/dev-bounce/SKILL.md`

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `~/.claude/hooks/plan-gate.sh` `/dev-bounce로` | ✅ PASS |
| TC-2 `~/.claude/hooks/doc-reminder.sh` `"block"` | ✅ PASS |
| TC-3 `~/.claude/agents/lead.md` `/dev-bounce로` | ✅ PASS |
| TC-4 `~/.claude/agents/planner-lead.md` `dev-bounce skill` | ✅ PASS |
| TC-5 `~/.claude/skills/dev-bounce/SKILL.md` `ExitPlanMode 절대 금지` | ✅ PASS |
