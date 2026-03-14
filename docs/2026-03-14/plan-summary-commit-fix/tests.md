| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | Phase 0-B에서 SIMPLE 판별 제거 | TASK_DIR 초기화만, mode: "pending" | ✅ |
| TC-02 | Phase 1 통합 (기존 S1/Phase 1 중복 제거) | Phase 1 1개, Phase S1 0개 | ✅ |
| TC-03 | Phase 1-B 복잡도 판별 신설 | Phase 1-B 섹션 존재 | ✅ |
| TC-04 | Step 5 plan 요약 품질 강화 | "plan.md의 핵심을 반영" 문구 존재 | ✅ |
| TC-05 | SIMPLE 커밋 전략 섹션 존재 | "S2 커밋" 섹션 + commit_strategy 테이블 | ✅ |
| TC-06 | NORMAL 커밋 실패 문구 수정 | per-step/per-phase 분기 명시 | ✅ |
| TC-07 | docs 구조 명세 존재 | "flat 파일" 금지 + "복수형" 명시 | ✅ |

## 실행출력

TC-01: grep -c "TASK_DIR 초기화" / "pending" / "복잡도 판별은 하지 않는다"
→ 2 / 1 / 1 (모두 존재)

TC-02: grep -c "## Phase 1: 계획 수립" / "### Phase S1"
→ 1 / 0 (통합됨, S1 제거)

TC-03: grep -c "Phase 1-B"
→ 3 (섹션 제목 + 참조 2건)

TC-04: grep -c "plan.md의 핵심을 반영"
→ 1

TC-05: grep -c "S2 커밋"
→ 1

TC-06: grep "per-step.*per-phase"
→ "커밋 실패 시 다음 진행 금지 — 원인 해결 후 재시도. (per-step: 다음 Step 차단, per-phase: 다음 Phase 차단)"

TC-07: grep -c "flat 파일" / "복수형"
→ 2 / 2
