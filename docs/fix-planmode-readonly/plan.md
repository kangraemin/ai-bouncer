# fix: TC-12 + plan mode 순서 + stale 태스크 자동 정리

## 변경 사항

### 1. `tests/test-plan-gate.sh` — TC-12 수정
- 1명 멤버 → ALLOW로 변경 (solo 팀 유효)
- `hooks/plan-gate.sh` 주석 "< 2" → "< 1"

### 2. `skills/dev-bounce/SKILL.md` — NORMAL 모드 Phase 1 순서 수정
- TASK_DIR 초기화를 Phase 0-B로 이동 (양 모드 공용)
- NORMAL: TeamCreate를 EnterPlanMode 앞으로 이동

### 3. `hooks/lib/resolve-task.sh` — stale 태스크 자동 정리
- 다른 session_id의 `.active` 발견 시: state.json의 workflow_phase 확인
- planning 상태(plan_approved=false)면 → stale로 판단, `.active` 삭제하고 무시
- development/verification 상태면 → 진행 중 작업이므로 무시(건드리지 않음)

### 4. `skills/dev-bounce/SKILL.md` — 컨텍스트 복원에 stale 정리 로직 추가
- 세션 시작 시 다른 세션의 미승인 planning 태스크 자동 정리

## 검증
- 전체 테스트 통과 (plan-gate, bash-gate, completion-gate)
- update.sh 실행
