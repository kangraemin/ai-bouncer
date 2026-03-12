# 문서 품질 검증 강화

## 변경 파일별 상세

### `hooks/plan-gate.sh`
- folder fallback + phase.md 필수 섹션 + step.md 실행출력 검증

### `hooks/completion-gate.sh`
- round.md 필수 섹션 체크

### `skills/dev-bounce/SKILL.md`
- TC 포맷 + plan.md 포맷 + phase.md 필수 섹션 명시

### `agents/lead.md`
- phase.md/step.md 템플릿 강화 + 품질 기준

### `agents/qa.md`
- 실행 결과 섹션 필수

### `agents/verifier.md`
- step 정합성 + 실행출력 체크

### `agents/planner-lead.md`
- plan.md Before/After 코드 필수

### `agents/planner-dev.md`
- 기술 분석에 코드 레벨 Before/After 필수

## 검증
- bash tests/e2e-hooks.sh
