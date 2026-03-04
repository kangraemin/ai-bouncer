# Step 5: Issue 4 — SKILL.md ExitPlanMode 오호출 방지 경고 추가

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n 'ExitPlanMode.*금지\|Q&A.*ExitPlanMode\|절대.*ExitPlanMode' skills/dev-bounce/SKILL.md` | 경고 문구 존재 |
| TC-2 | `grep -n 'AskUserQuestion' skills/dev-bounce/SKILL.md` | Q&A에 AskUserQuestion 사용 명시 존재 |

## 구현 내용

`skills/dev-bounce/SKILL.md` Phase 1-3 Q&A 루프 섹션에 경고 추가:
- Q&A 루프 중 ExitPlanMode 호출 금지 명시
- 사용자 질문 전달은 반드시 AskUserQuestion 사용

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `ExitPlanMode 절대 금지` 경고 (line 89) | ✅ PASS |
| TC-2 `AskUserQuestion` 사용 명시 (line 90, 97) | ✅ PASS |
