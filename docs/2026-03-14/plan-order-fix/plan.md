# SKILL.md Phase 1 순서 수정: plan mode plan → plan.md

## 변경 파일별 상세

### `skills/dev-bounce/SKILL.md`

- **변경 이유**: Phase 1에서 plan.md를 먼저 쓰고 plan mode plan에 "요약"하라고 해서, plan mode plan(사용자에게 보이는 것)이 부실해지는 문제. 순서를 뒤집어 plan mode plan을 원본으로, plan.md를 승인 후 생성하도록 변경.

- **Before** (현재 step 4~7):
```
4. {TASK_DIR}/plan.md 작성 (plan mode 안에서 Write, Before/After 필수)
5. plan mode 내부 plan 파일에 계획 요약 정리 — plan.md의 핵심을 반영
6. 계획 요약을 텍스트로 사용자에게 출력
7. ExitPlanMode 호출 → accept/reject
8. state.json 업데이트
```

- **After** (수정 후):
```
4. plan mode plan 파일에 상세 계획 작성 (Before/After 포함)
   — 사용자에게 보이는 원본. 대충 쓸 수 없음.
5. 계획을 텍스트로 사용자에게 출력
6. ExitPlanMode 호출 → accept/reject
7. 승인 후 plan mode plan 기반으로 {TASK_DIR}/plan.md 생성
   — Before/After 전체 코드 + 구조화된 형식
8. state.json 업데이트
```

## 검증
- `grep -c "plan mode plan 파일에 상세 계획" skills/dev-bounce/SKILL.md` → 1 이상
- Phase 1 step 순서 확인: plan mode plan → ExitPlanMode → plan.md
