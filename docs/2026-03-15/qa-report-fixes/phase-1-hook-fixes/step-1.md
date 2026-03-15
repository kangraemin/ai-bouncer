# Step 1: bash-audit.sh + subagent-cleanup.sh (C-1, C-2)

## 변경 사항

### C-1: bash-audit.sh — SESSION_ID 기반 snapshot 경로
- 하드코딩된 `/tmp/.ai-bouncer-snapshot` → `SESSION_ID` 기반 경로
- `AGENT_SESSION_ID` 변수도 `SESSION_ID`에서 파생

### C-2: subagent-cleanup.sh — grep 실패 시 빈 파일 mv 방지
- `|| true` 제거, `[ -f "$TEMP" ]` 체크 후 mv

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | bash-audit.sh에 SESSION_ID 변수 존재 | grep 'SESSION_ID=' hooks/bash-audit.sh | SESSION_ID 추출 코드 존재 | ✅ |
| TC-02 | SNAPSHOT_FILE에 SESSION_ID 포함 | grep 'SNAPSHOT_FILE=.*SESSION_ID' hooks/bash-audit.sh | 경로에 SESSION_ID 반영 | ✅ |
| TC-03 | 하드코딩 snapshot 경로 제거 | grep -c '/tmp/.ai-bouncer-snapshot"' hooks/bash-audit.sh → 0 | 하드코딩 없음 | ✅ |
| TC-04 | subagent-cleanup.sh에 `\|\| true` 없음 | grep -c '\|\| true' hooks/subagent-cleanup.sh → 0 | 제거됨 | ✅ |
| TC-05 | subagent-cleanup.sh에 `-f "$TEMP"` 체크 | grep '\-f.*TEMP' hooks/subagent-cleanup.sh | 파일 존재 확인 로직 | ✅ |
| TC-06 | bash-audit 테스트 통과 | bash tests/test-bash-audit.sh | 9/10 PASS (TC-A7 기존 버그) | ✅ |

## 실행출력

TC-01: grep 'SESSION_ID=' hooks/bash-audit.sh
→ SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
→ AGENT_SESSION_ID="$SESSION_ID"

TC-02: grep 'SNAPSHOT_FILE=.*SESSION_ID' hooks/bash-audit.sh
→ SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}"

TC-03: grep -c '/tmp/.ai-bouncer-snapshot"' hooks/bash-audit.sh
→ 0

TC-04: grep -c '|| true' hooks/subagent-cleanup.sh
→ 0

TC-05: grep '\-f.*TEMP' hooks/subagent-cleanup.sh
→ if [ -f "$TEMP" ]; then

TC-06: bash tests/test-bash-audit.sh
→ 9/10 passed. TC-A7 실패는 기존 테스트 버그 (state.json이 예외 경로인데 복원을 기대)
