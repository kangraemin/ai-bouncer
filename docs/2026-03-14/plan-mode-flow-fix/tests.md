| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | Phase S1에서 ExitPlanMode가 승인 후에 호출되는 흐름 | plan.md를 plan mode 안에서 작성 → ExitPlanMode = 승인 | ✅ |
| TC-02 | Phase 1에서 동일 흐름 적용 | NORMAL 모드도 plan mode 안에서 계획 제시 + ExitPlanMode = 승인 | ✅ |
| TC-03 | Phase 2 간소화 | 별도 승인 신호 감지 제거, ExitPlanMode 후 바로 Phase 3 | ✅ |
| TC-04 | Phase S2 승인 신호 감지 제거 | ExitPlanMode 시점에 이미 승인, 텍스트 승인 불필요 | ✅ |
| TC-05 | plan-gate.sh 호환성 | plan.md는 plan-gate에서 이미 허용 (CHECK 1) | ✅ |

## 실행출력

TC-01: `grep "ExitPlanMode 호출 = .*사용자 승인" skills/dev-bounce/SKILL.md`
→ 라인 196: `ExitPlanMode 호출 = **사용자 승인 완료** (plan mode UI에서 계획을 확인하고 승인하는 자연스러운 흐름)`

TC-02: `grep "ExitPlanMode 호출 = .*사용자 승인" skills/dev-bounce/SKILL.md`
→ 라인 292: `ExitPlanMode 호출 = **사용자 승인 완료**`

TC-03: `grep "승인 신호 감지" skills/dev-bounce/SKILL.md`
→ No matches found (제거됨)

TC-04: `grep "PLAN:승인대기" skills/dev-bounce/SKILL.md`
→ No matches found (제거됨)

TC-05: `grep "plan.md" hooks/plan-gate.sh`
→ 라인 28: `if [[ "$FILE_PATH" == */plan.md ]]` — 허용됨
