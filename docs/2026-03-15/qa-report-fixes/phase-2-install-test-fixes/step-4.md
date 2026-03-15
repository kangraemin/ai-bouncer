# Step 4: tests (I-6)

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | test-bash-gate.sh HOME override | grep 'FAKE_HOME\|HOME=' tests/test-bash-gate.sh | HOME 임시 디렉토리 사용 | ✅ |
| TC-02 | test-plan-gate.sh HOME override | grep 'FAKE_HOME\|HOME=' tests/test-plan-gate.sh | HOME 임시 디렉토리 사용 | ✅ |
| TC-03 | test-bash-gate 통과 | bash tests/test-bash-gate.sh | 29/33 (기존 4건 실패 동일) | ✅ |
| TC-04 | test-plan-gate 통과 | bash tests/test-plan-gate.sh | 21/25 (기존 4건 실패 동일) | ✅ |

## 실행출력

TC-01~02: FAKE_HOME 변수 설정 + HOME override 확인
TC-03: bash tests/test-bash-gate.sh → 29/33 passed (기존과 동일)
TC-04: bash tests/test-plan-gate.sh → 21/25 passed (기존과 동일)
HOME 오염 확인: 테스트 후 $HOME/.claude/teams/에 nonexistent-team-* 없음 (정상)
