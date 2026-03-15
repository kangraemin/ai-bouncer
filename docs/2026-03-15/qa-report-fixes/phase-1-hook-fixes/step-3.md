# Step 3: plan-gate.sh (I-1, M-1)

## 변경 사항

### I-1: 산술 비교 변수 sanitize
- MEMBER_COUNT, CURRENT_DEV_PHASE, CURRENT_STEP 비교 전 숫자 외 문자 제거

### M-1: 한국어 grep 로케일
- 한국어 패턴 grep 앞에 `LC_ALL=en_US.UTF-8` 추가

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | I-1: MEMBER_COUNT sanitize | grep 'MEMBER_COUNT.*[^0-9]' hooks/plan-gate.sh | sanitize 코드 | ✅ |
| TC-02 | I-1: CURRENT_DEV_PHASE sanitize | grep 'CURRENT_DEV_PHASE.*[^0-9]' hooks/plan-gate.sh | sanitize 코드 | ✅ |
| TC-03 | I-1: CURRENT_STEP sanitize | grep 'CURRENT_STEP.*[^0-9]' hooks/plan-gate.sh | sanitize 코드 | ✅ |
| TC-04 | M-1: LC_ALL 한국어 grep | grep 'LC_ALL=en_US.UTF-8' hooks/plan-gate.sh | 로케일 설정 | ✅ |
| TC-05 | plan-gate 테스트 통과 | bash tests/test-plan-gate.sh | 21/25 PASS (4건 기존 버그) | ✅ |

## 실행출력

TC-01~04: grep 확인 완료 — sanitize 코드 및 LC_ALL 설정 존재

TC-05: bash tests/test-plan-gate.sh
→ 21/25 passed. 4건 실패(TC-4, TC-12, TC-AM1, TC-AM4)는 기존 버그 (변경 전과 동일)
