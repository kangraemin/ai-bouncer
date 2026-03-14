| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | SIMPLE Phase S1에서 ExitPlanMode 직접 호출 지시 제거 | "Claude가 ExitPlanMode를 직접 호출하지 않는다" 문구 존재 | ✅ |
| TC-02 | NORMAL Phase 1에서 ExitPlanMode 직접 호출 지시 제거 | 동일 문구 존재 | ✅ |
| TC-03 | 소스↔설치본 동기화 | diff 결과 없음 | ✅ |
| TC-04 | SKILL.md에 "ExitPlanMode 호출 = 사용자 승인" 잔존 없음 | grep 결과 0건 | ✅ |

## 실행출력

TC-01: grep "Claude가 ExitPlanMode를 직접 호출하지 않는다" skills/dev-bounce/SKILL.md (Phase S1 부근)
→ 2건 매칭 (SIMPLE + NORMAL)

TC-02: 위와 동일 — NORMAL 모드 Phase 1에도 존재 확인

TC-03: diff <(sed -n '5,$p' skills/dev-bounce/SKILL.md) <(sed -n '5,$p' .claude/skills/dev-bounce/SKILL.md)
→ 출력 없음 (일치)

TC-04: grep "ExitPlanMode 호출 = " skills/dev-bounce/SKILL.md .claude/skills/dev-bounce/SKILL.md
→ 0건 (제거 확인)
