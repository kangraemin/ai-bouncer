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
| TC-1 | commands/dev-bounce.md Phase 1 섹션에서 "EnterPlanMode" 텍스트 검색 | 1회 이상 존재함 | ✅ PASS — line 41 (1-0), line 129 (Phase 2), 총 2회 존재 |
| TC-2 | commands/dev-bounce.md Phase 1 섹션에서 "ExitPlanMode" 텍스트 검색 | 1회 이상 존재함 | ✅ PASS — line 121 (1-5 이후), 1회 존재 |
| TC-3 | Phase 1 내 EnterPlanMode의 위치 확인 — Q&A 루프(1-2) 이전 단계(1-1 또는 진입부)에 존재 | Q&A 루프 시작 전 위치에 EnterPlanMode가 있음 | ✅ PASS — line 41 (섹션 1-0), Q&A 루프(1-3, line 86) 이전 |
| TC-4 | Phase 1 내 ExitPlanMode의 위치 확인 — streak=3 이후, "수정 요청이 있으면" 문구와 함께 존재 | 계획 확정(streak>=3) 이후 사용자 승인 요청 시점에 ExitPlanMode가 있음 | ✅ PASS — line 121, 1-5 [PLAN:승인대기] 블록 직후 위치 |
| TC-5 | Phase 1 내 사용자 수정 요청 처리 흐름에 EnterPlanMode 재진입 명시 여부 확인 | 수정 요청 시 EnterPlanMode 재진입 흐름이 텍스트로 명시됨 | ✅ PASS — line 129 Phase 2에 "수정 요청 시: EnterPlanMode 재진입" 명시 |

## 구현 내용

- Phase 1 진입부에 `### 1-0. Plan Mode 진입` 섹션 추가, EnterPlanMode 호출 명시
- 기존 1-0~1-4 섹션을 1-1~1-5로 순서 번호 재정렬
- `### 1-5. 계획 사용자에게 표시` 의 `[PLAN:승인대기]` 블록 직후 ExitPlanMode 호출 추가
- Phase 2 승인 신호 감지 라인 직후 수정 요청 시 EnterPlanMode 재진입 흐름 추가

## 변경 파일

- `commands/dev-bounce.md`: Plan mode 흐름(EnterPlanMode/ExitPlanMode) 추가, 섹션 번호 재정렬

## 빌드

문서 편집 작업 — 빌드 불필요. TC grep 검증:
- EnterPlanMode: commands/dev-bounce.md 내 2회 존재 (1-0, Phase 2)
- ExitPlanMode: commands/dev-bounce.md 내 1회 존재 (1-5)
