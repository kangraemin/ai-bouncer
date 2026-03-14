| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | install.sh에서 --update 주석 제거됨 | `grep "\-\-update" install.sh` 결과 없음 | ✅ |
| TC-02 | SKILL.md Phase 0-B 중복 문장 제거 | line 120에 `[INTENT:개발요청]` 없음 | ✅ |
| TC-03 | SKILL.md .active 파일 why 보강 | `세션 간 충돌 방지` 문구 포함 | ✅ |
| TC-04 | e2e 테스트 통과 | 전체 통과 (FAIL 0) | ✅ |

## 실행출력

TC-01: `grep "\-\-update" install.sh`
→ EXIT:1 (매칭 없음 = 제거 확인)

TC-02: `sed -n '120p' skills/dev-bounce/SKILL.md`
→ TASK_DIR을 초기화한다. **복잡도 판별은 하지 않는다** — Phase 1-B에서 plan 기반으로 판별하기 때문.

TC-03: `grep "세션 간 충돌 방지" skills/dev-bounce/SKILL.md`
→ 4. `.active` 파일 생성 (빈 파일 — hook이 session_id를 자동 claim하여 세션 간 충돌 방지)

TC-04: `bash tests/e2e-full.sh`
→ 결과: ✅ 66 통과 / ❌ 0 실패
