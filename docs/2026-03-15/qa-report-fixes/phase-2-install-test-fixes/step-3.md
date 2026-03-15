# Step 3: uninstall.sh (M-2)

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | M-2: hooks.json 동적 읽기 | grep 'hooks.json' uninstall.sh | hooks.json 경로 참조 | ✅ |
| TC-02 | M-2: fallback 하드코딩 유지 | grep 'plan-gate.sh' uninstall.sh | fallback set 존재 | ✅ |
| TC-03 | C-5: inline open('$') 제거 | grep -c "open('\$" uninstall.sh → 0 | 인라인 경로 없음 | ✅ |

## 실행출력

TC-01: hooks.json 동적 읽기 코드 존재 확인
TC-02: fallback BOUNCER_HOOKS set에 plan-gate.sh 포함
TC-03: open('$...') 패턴 0건
