# phase.md 존재 검증 gate 강화

## 변경 사항
- `hooks/plan-gate.sh`: CHECK 7a — phase.md 존재 검증 추가
- `hooks/bash-gate.sh`: 동일 CHECK 7a 추가
- `tests/test-plan-gate.sh`: setup_env에 phase.md 생성 + TC-PH1 추가
- `tests/test-bash-gate.sh`: setup_env에 phase.md 생성 + TC-BPH1 추가

## 검증
- `bash tests/test-plan-gate.sh` 전체 통과
- `bash tests/test-bash-gate.sh` 전체 통과
