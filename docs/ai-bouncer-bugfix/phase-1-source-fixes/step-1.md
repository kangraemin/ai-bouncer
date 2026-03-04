# Step 1: Issue 3 — `/dev` → `/dev-bounce` 참조 수정

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n '/dev로\|/dev <\|commands/dev\.md' install.sh hooks/plan-gate.sh agents/lead.md agents/planner-lead.md` | 결과 없음 |
| TC-2 | `grep -n '/dev-bounce' hooks/plan-gate.sh` | line 50에 `/dev-bounce로` 존재 |
| TC-3 | `grep -n '/dev-bounce' install.sh` | 완료 메시지에 `/dev-bounce` 존재 |
| TC-4 | `grep -n 'dev-bounce skill' agents/lead.md agents/planner-lead.md` | 각 파일에 존재 |

## 구현 내용

변경 파일:
- `install.sh` line 509: `/dev <요청>` → `/dev-bounce <요청>`
- `hooks/plan-gate.sh` line 50: `/dev로 계획을` → `/dev-bounce로 계획을`
- `agents/lead.md` line 22: `/dev로 계획 승인` → `/dev-bounce로 계획 승인`
- `agents/planner-lead.md` lines 68, 77: `commands/dev.md` → `dev-bounce skill`

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `/dev로\|/dev <\|commands/dev\.md` 없음 | ✅ PASS |
| TC-2 plan-gate.sh line 50 `/dev-bounce로` | ✅ PASS |
| TC-3 install.sh line 509 `/dev-bounce <요청>` | ✅ PASS |
| TC-4 lead.md, planner-lead.md에 `dev-bounce skill` | ✅ PASS |
