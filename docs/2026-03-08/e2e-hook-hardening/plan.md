# E2E Hook Hardening — 전체 검증 + 구조 불일치 수정

## 발견된 문제

### 버그
1. **bash-gate: `\bpython\b` 없이 `\bpython`으로 매칭** — `python_version` 같은 변수명도 잡힘
2. **bash-audit: 스냅샷이 bash-gate 차단 시에만 생성** — bash-gate가 통과시킨 명령이 몰래 파일 쓰면 audit이 못 잡음 (스냅샷 없으니까)
3. **completion-gate: 위임 에이전트도 차단** — sub-agent가 Stop할 때 completion-gate가 발동, verification 미완료로 차단
4. **resolve-task: `return 0` 소싱 환경 문제** — source 시 `return 0`이 호출자 스크립트도 종료시킬 수 있음 (현재 `|| :` fallback 있지만 불안정)
5. **bash-gate: tests.md 예외 누락** — SIMPLE 모드에서 TC 작성 시 tests.md를 Bash로 쓸 때 차단됨
6. **bash-gate: .active 파일 삭제 차단** — dev-bounce 완료 시 `rm -f .active`가 bash-gate에 잡힘

### 누락 기능
7. **승인 목록 stale 방지** — 크래시 시 /tmp/.ai-bouncer-approved-agents 잔존, 재부팅까지 남음
8. **plan-gate/bash-gate: 위임 에이전트 state 로딩 누락** — resolve-task에서 IS_DELEGATED_AGENT=true면 NORMAL 모드 체크(team_name, step 등) 스킵해야 함
9. **bash-audit: state.json 예외 누락** — state.json 수정이 무단 변경으로 복원될 수 있음
10. **subagent-track: 날짜 디렉토리 glob 패턴 오류** — `"$date_dir"*/.active` → `"$date_dir"*/.active` 사이 `/` 누락 가능

## 변경 사항
- `hooks/bash-gate.sh`: python 정규식 수정, tests.md/.active 예외 추가
- `hooks/bash-audit.sh`: state.json 예외 추가, 스냅샷 없을 때 독립 감지 모드
- `hooks/completion-gate.sh`: 위임 에이전트 스킵
- `hooks/plan-gate.sh`: 위임 에이전트의 NORMAL 체크 스킵
- `hooks/lib/resolve-task.sh`: return 안정화
- `hooks/subagent-track.sh`: glob 패턴 수정, stale 정리
- `hooks/subagent-cleanup.sh`: (변경 없음)

## TC
- E2E 테스트 스크립트로 전체 시나리오 검증
