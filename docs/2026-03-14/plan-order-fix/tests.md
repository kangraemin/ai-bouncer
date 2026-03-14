| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | plan mode plan이 원본으로 먼저 작성되는 순서 | step 4에서 "plan mode plan 파일에 상세 계획 작성" 문구 존재 | ✅ |
| TC-02 | plan.md가 ExitPlanMode 승인 후 생성되는 순서 | ExitPlanMode 이후 step에서 plan.md 생성 지시 존재 | ✅ |
| TC-03 | 기존 "요약 정리" 문구 제거 | "plan mode 내부 plan 파일에 계획 요약 정리" 문구 없음 | ✅ |
| TC-04 | plan.md 템플릿(Before/After) 유지 | plan.md 작성 시 Before/After 템플릿 포함 | ✅ |
| TC-05 | plan mode plan 작성 시 부실 요약 금지 경고 유지 | "파일명: 한 줄 설명" 금지 경고 존재 | ✅ |

## 실행출력

TC-01: `grep -c "plan mode plan 파일에 상세 계획 작성" skills/dev-bounce/SKILL.md`
→ 1

TC-02: `grep -c "승인 후.*plan.md" skills/dev-bounce/SKILL.md`
→ 1

TC-03: `grep -c "plan mode 내부 plan 파일에 계획 요약 정리" skills/dev-bounce/SKILL.md`
→ 0 (제거됨)

TC-04: `grep -c "Before.*현재 코드" skills/dev-bounce/SKILL.md`
→ 1

TC-05: `grep -c "파일명: 한 줄 설명" skills/dev-bounce/SKILL.md`
→ 1
