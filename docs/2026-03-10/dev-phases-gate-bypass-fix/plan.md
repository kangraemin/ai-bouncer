# dev_phases 빈 객체/누락 시 gate 우회 버그 수정

## 변경 사항
- `hooks/plan-gate.sh`: CHECK 6.5 뒤에 CHECK 6.7 (dev_phases 유효성 검증) 추가
- `hooks/bash-gate.sh`: 동일 CHECK 6.7 추가 (save_snapshot + [bash-gate] prefix)

## 검증
- `bash tests/e2e-hooks.sh` 기존 25건 회귀 없음
- dev_phases={} 상태에서 Write/Bash 요청 시 block 확인
