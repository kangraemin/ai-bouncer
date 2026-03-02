# Step 3: Plan mode 흐름 추가 (기능 5: EnterPlanMode/ExitPlanMode)

## 완료 기준
- Phase 1 섹션에 EnterPlanMode 호출이 존재함
- Phase 1 섹션에 ExitPlanMode 호출이 존재함
- EnterPlanMode는 Phase 1 진입 직후(Q&A 루프 시작 전)에 위치함
- ExitPlanMode는 streak=3(계획 확정) 이후, 사용자 승인 요청 시점에 위치함
- 사용자 수정 요청 시 EnterPlanMode 재진입 흐름이 명시됨

## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | commands/dev-bounce.md Phase 1 섹션에서 "EnterPlanMode" 텍스트 검색 | 1회 이상 존재함 | |
| TC-2 | commands/dev-bounce.md Phase 1 섹션에서 "ExitPlanMode" 텍스트 검색 | 1회 이상 존재함 | |
| TC-3 | Phase 1 내 EnterPlanMode의 위치 확인 — Q&A 루프(1-2) 이전 단계(1-1 또는 진입부)에 존재 | Q&A 루프 시작 전 위치에 EnterPlanMode가 있음 | |
| TC-4 | Phase 1 내 ExitPlanMode의 위치 확인 — streak=3 이후, "수정 요청이 있으면" 문구와 함께 존재 | 계획 확정(streak>=3) 이후 사용자 승인 요청 시점에 ExitPlanMode가 있음 | |
| TC-5 | Phase 1 내 사용자 수정 요청 처리 흐름에 EnterPlanMode 재진입 명시 여부 확인 | 수정 요청 시 EnterPlanMode 재진입 흐름이 텍스트로 명시됨 | |
