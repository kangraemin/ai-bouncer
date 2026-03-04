# Step 2: Issue 2 — doc-reminder.sh warn → block

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n '"warn"' hooks/doc-reminder.sh` | 결과 없음 |
| TC-2 | `grep -n '"block"' hooks/doc-reminder.sh` | 존재 |
| TC-3 | `grep -n 'reason' hooks/doc-reminder.sh` | `reason` 키 사용 (warn 대신) |

## 구현 내용

`hooks/doc-reminder.sh` line 46~49:
- `decision: "warn"` → `decision: "block"`
- `message` → `reason` (block 결정의 표준 키)

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `"warn"` 없음 | ✅ PASS |
| TC-2 `"block"` 존재 | ✅ PASS |
| TC-3 `reason` 키 사용 | ✅ PASS |
