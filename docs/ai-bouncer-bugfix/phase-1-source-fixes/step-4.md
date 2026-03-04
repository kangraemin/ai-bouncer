# Step 4: Issue 1-B — commit 스킬 감지 개선 + 재시작 안내

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n 'skills/commit' install.sh` | `~/.claude/skills/commit/SKILL.md` 감지 로직 존재 |
| TC-2 | `grep -n '재시작\|restart' install.sh` | 재시작 안내 메시지 존재 |
| TC-3 | `grep -n 'COMMIT_SKILL_BOOL' install.sh` | for loop 또는 다중 경로 체크 구조 |

## 구현 내용

`install.sh`:
- commit 스킬 감지: `commands/commit.md` + `skills/commit/SKILL.md` 경로 모두 체크 (for loop)
- 완료 메시지에 "Claude Code를 재시작해야 스킬이 활성화됩니다" 안내 추가

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `skills/commit/SKILL.md` 감지 로직 | ✅ PASS (line 365, 367) |
| TC-2 재시작 안내 메시지 | ✅ PASS (line 519) |
| TC-3 for loop 다중 경로 체크 | ✅ PASS (line 362~374) |
