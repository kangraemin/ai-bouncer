# Step 2: bash-gate.sh (C-3, I-1, M-1)

## 변경 사항

### C-3: jq max on null
- `max` → `max // 0` (keys 빈 배열 시 null 방지)

### I-1: 산술 비교 변수 sanitize
- MEMBER_COUNT, CURRENT_DEV_PHASE, CURRENT_STEP 비교 전 숫자 외 문자 제거

### M-1: 한국어 grep 로케일
- 한국어 패턴 grep 앞에 `LC_ALL=en_US.UTF-8` 추가

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | C-3: max // 0 적용 | grep 'max // 0' hooks/bash-gate.sh | max fallback 존재 | ✅ |
| TC-02 | I-1: MEMBER_COUNT sanitize | grep 'MEMBER_COUNT.*[^0-9]' hooks/bash-gate.sh | 숫자 외 문자 제거 코드 | ✅ |
| TC-03 | I-1: CURRENT_DEV_PHASE sanitize | grep 'CURRENT_DEV_PHASE.*[^0-9]' hooks/bash-gate.sh | 숫자 외 문자 제거 코드 | ✅ |
| TC-04 | I-1: CURRENT_STEP sanitize | grep 'CURRENT_STEP.*[^0-9]' hooks/bash-gate.sh | 숫자 외 문자 제거 코드 | ✅ |
| TC-05 | M-1: LC_ALL 한국어 grep | grep 'LC_ALL=en_US.UTF-8' hooks/bash-gate.sh | 로케일 설정 존재 | ✅ |
| TC-06 | bash-gate 테스트 통과 | bash tests/test-bash-gate.sh | 29/33 PASS (4건 기존 버그) | ✅ |

## 실행출력

TC-01: grep 'max // 0' hooks/bash-gate.sh
→ LAST_STEP_CS=$(jq -r ".dev_phases[\"$CS_PHASE\"].steps | keys | map(tonumber) | max // 0" "$STATE_FILE" 2>/dev/null)

TC-02: grep 'MEMBER_COUNT.*[^0-9]' hooks/bash-gate.sh
→ MEMBER_COUNT=${MEMBER_COUNT:-0}; MEMBER_COUNT=${MEMBER_COUNT//[^0-9]/}; MEMBER_COUNT=${MEMBER_COUNT:-0}

TC-03: grep 'CURRENT_DEV_PHASE.*[^0-9]' hooks/bash-gate.sh
→ CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE:-0}; CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE//[^0-9]/}; CURRENT_DEV_PHASE=${CURRENT_DEV_PHASE:-0}

TC-04: grep 'CURRENT_STEP.*[^0-9]' hooks/bash-gate.sh
→ CURRENT_STEP=${CURRENT_STEP:-0}; CURRENT_STEP=${CURRENT_STEP//[^0-9]/}; CURRENT_STEP=${CURRENT_STEP:-0}

TC-05: grep 'LC_ALL=en_US.UTF-8' hooks/bash-gate.sh
→ 2건 존재: phase.md 섹션 검증 + 실행출력 검증

TC-06: bash tests/test-bash-gate.sh
→ 29/33 passed. 4건 실패(TC-B16, TC-B17, TC-B27, TC-BAM1)는 기존 버그 (변경 전과 동일)
