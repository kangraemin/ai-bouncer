# 구현 계획: dev-bounce 강제화 강화 + SKILL.md 누락 로직 복원

## Context

전체 분석 결과 두 가지 근본 원인 발견:

1. **plan-gate.sh 강제화 구멍**: state.json `test_defined` 플래그만 체크 → 플래그만 수동 설정하면 step-M.md 없이도 코드 작성 가능
2. **SKILL.md 누락 로직 (핵심)**: `e2e-skill.sh`이 "verbatim from SKILL.md"라고 명시한 두 로직이 현재 SKILL.md에 없음
   - **Phase 1-1 persistent_mode**: 워크트리/docs_git_track=false 시 task_dir를 `~/.claude/ai-bouncer/sessions/{repo}/docs/`에 저장하는 로직
   - **Phase 4-4 copy**: 완료 시 persistent → main repo로 docs 복사하는 로직 (`shutil.rmtree(dst)` + `shutil.copytree`)

---

## Phase 1: SKILL.md — Phase 1-1 persistent_mode 로직 복원

- `skills/dev-bounce/SKILL.md` + `~/.claude/skills/dev-bounce/SKILL.md` 동기화
- TASK_DIR 초기화 섹션에 persistent_mode 로직 추가
- 컨텍스트 복원 로직에 persistent_active 경로 추가

## Phase 2: SKILL.md — Phase 4-4 copy 로직 추가 + 완료 동작 명확화

- Phase 4 `[DONE]` 수신 섹션 변경
- persistent_mode 시 main repo로 docs 복사 (shutil.copytree)
- task_dir(source) 삭제 금지 주의사항 추가

## Phase 3: plan-gate.sh — `doc_created` 플래그 체크 추가

- TEST_DEFINED 체크 블록 다음에 DOC_CREATED 체크 블록 추가
- `cp hooks/plan-gate.sh ~/.claude/hooks/plan-gate.sh` 동기화

## Phase 4: lead.md + qa.md — `doc_created` 플래그 관리 추가

- lead.md: step.md 뼈대 생성 후 state.json `doc_created = true` 설정
- state.json step 구조에 `doc_created: false` 필드 추가

## Phase 5: tests/test-plan-gate.sh — TC-7 추가

- TC-7: dev + team_spawned=true + test_defined=true + doc_created=false + Write to /src/feature.ts → BLOCK
