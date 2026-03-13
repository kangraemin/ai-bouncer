# 모드 조합 통합 워크플로우 E2E 테스트

## Context
6가지 모드 조합(team/subagent/single × hooks/prompt-only)의 전체 워크플로우 통합 테스트 작성.

## 신규 파일

### `tests/e2e-workflow.sh`
- **용도**: 모든 모드 조합의 NORMAL 모드 전체 워크플로우 시뮬레이션
- **핵심 코드**: simulate_hooks_workflow (W1~W18) + simulate_prompt_only_workflow (P1~P4)

## 검증
- 검증 명령어: `bash tests/e2e-workflow.sh`
- 기대 결과: ~84 assertions 전부 통과
