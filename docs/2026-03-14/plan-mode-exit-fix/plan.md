# plan mode ExitPlanMode 즉시 호출 문제 수정

## 변경 파일별 상세
### `skills/dev-bounce/SKILL.md`
- **변경 이유**: plan mode에서 계획 작성 직후 ExitPlanMode를 같은 턴에 호출하여 사용자가 계획을 검토/수정할 기회가 없음
- **Before** (현재 코드 — Phase S1 step 5~6):
```
5. plan mode 내부 plan 파일에도 계획 요약 정리 (사용자가 plan mode UI에서 확인)
6. ExitPlanMode 호출 = **사용자 승인 완료** (plan mode UI에서 계획을 확인하고 승인하는 자연스러운 흐름)
7. state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`
```
- **After** (변경 후):
```
5. plan mode 내부 plan 파일에도 계획 요약 정리
6. 계획 요약을 텍스트로 사용자에게 출력 + "수정 요청이 있으면 말씀해주세요. 승인하시면 개발을 시작합니다." 안내
   ⚠️ **이 턴에서 ExitPlanMode를 호출하지 않는다.** 반드시 사용자 응답을 기다린다.
7. 사용자 응답 처리:
   - 수정 요청 → plan.md 수정 → 다시 요약 출력 + 대기 (step 6 반복)
   - 승인 신호 (`승인`, `ㄱㄱ`, `ㅇㅇ`, `진행`, `go`, `ok`, `시작`) → ExitPlanMode 호출
8. state.json 업데이트: `plan_approved = true`, `workflow_phase = "development"`
```
- **영향 범위**: Phase S1 (SIMPLE), Phase 1 (NORMAL) 둘 다 동일 패턴이므로 양쪽 수정

### `.claude/skills/dev-bounce/SKILL.md`
- **변경 이유**: 설치본과 소스 동기화
- 소스(`skills/dev-bounce/SKILL.md`)와 동일하게 수정

## 검증
- 검증 명령어: `diff skills/dev-bounce/SKILL.md .claude/skills/dev-bounce/SKILL.md`
- 기대 결과: frontmatter 차이 외 내용 동일
