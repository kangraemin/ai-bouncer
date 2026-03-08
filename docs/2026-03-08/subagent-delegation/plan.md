# SubagentStart/Stop 기반 위임 컨텍스트 추적

## 문제
- sub-agent가 /dev-bounce를 호출해 자체 task 생성 → stale .active → 메인 세션 차단
- bash-audit이 sub-agent의 정상 쓰기를 무단 변경으로 판단 → 자동 복원

## 해결 방향
SubagentStart/Stop hook으로 승인된 에이전트를 추적.
hook들이 승인된 에이전트의 쓰기를 부모 task 기준으로 검증.

## 변경 사항
- `hooks/subagent-track.sh`: SubagentStart hook — 승인 목록에 session_id 기록
- `hooks/subagent-cleanup.sh`: SubagentStop hook — 승인 목록에서 제거
- `hooks/lib/resolve-task.sh`: 승인된 에이전트면 부모 task로 fallback
- `hooks/plan-gate.sh`: resolve-task 결과 활용 (변경 최소)
- `hooks/bash-gate.sh`: 동일
- `hooks/bash-audit.sh`: 승인된 에이전트의 쓰기는 스냅샷 비교 스킵
- `install.sh`: SubagentStart/Stop hook 등록 추가

## 검증
- sub-agent 스폰 시 session_id가 승인 목록에 추가되는지 확인
- 승인된 에이전트의 Write가 부모 task 기준으로 통과하는지 확인
- 승인되지 않은 세션의 Write가 여전히 차단되는지 확인
- sub-agent 종료 시 목록에서 제거되는지 확인
