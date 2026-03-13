| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | TC:skip 제거 | README.md에 `TC:skip` 문자열 없음 | ✅ |
| TC-02 | SIMPLE TC 흐름 보강 | `mandatory` + `execution output` 언급 존재 | ✅ |
| TC-03 | agent_mode별 설명 추가 | `single` + `subagent` + `team` 모드별 Phase 3/4 동작 테이블 존재 | ✅ |
| TC-04 | TC 포맷 반영 | `execution output` 관련 언급 존재 | ✅ |

## 실행출력

TC-01: `grep -c "TC:skip\|TC skip" README.md`
→ 0 matches (Found 0 total occurrences across 0 files)

TC-02: `grep -n "mandatory\|execution output" README.md`
→ line 81: `(table + execution output format, mandatory)` 확인
→ line 112: `records actual execution output as evidence`
→ line 218: `TC table + implementation + execution output evidence`

TC-03: `grep -n "single.*Main Claude\|subagent.*Agent tool" README.md`
→ line 99: `subagent | Agent tool → Lead + Dev + QA agents`
→ line 100: `single | Main Claude directly (phase/step structure maintained)`
→ line 195: `2) subagent (Agent tool) · 3) single (Main Claude only)`

TC-04: `grep -n "execution output" README.md`
→ line 81, 112, 113, 218에서 확인 (TC-02와 동일)
