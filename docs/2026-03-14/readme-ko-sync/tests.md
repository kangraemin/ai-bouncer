| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | planner 에이전트 제거 | `planner` 문자열 0건 | ✅ |
| TC-02 | TC:스킵 제거 | `TC:스킵` 또는 `TC:skip` 0건 | ✅ |
| TC-03 | solo 팀 제거 | `solo` 문자열 0건 | ✅ |
| TC-04 | agent_mode 설명 존재 | `single` + `subagent` 모드 언급 | ✅ |
| TC-05 | stop-bouncer-compat 추가 | hook 테이블에 존재 | ✅ |
| TC-06 | 실행출력 증거 언급 | `실행출력` 관련 표현 존재 | ✅ |

## 실행출력

TC-01: `grep -c "planner" README.ko.md`
→ 0 (Found 0 total occurrences across 0 files)

TC-02: `grep -c "TC:스킵\|TC:skip" README.ko.md`
→ 0 (Found 0 total occurrences across 0 files)

TC-03: `grep -c "solo" README.ko.md`
→ 0 (Found 0 total occurrences across 0 files)

TC-04: `grep -n "single\|subagent" README.ko.md`
→ line 99: `subagent | Agent tool → Lead + Dev + QA 에이전트`
→ line 100: `single | 메인 Claude가 직접 수행`
→ line 195: `2) subagent (Agent tool) · 3) single (메인 Claude만)`

TC-05: `grep -c "stop-bouncer-compat" README.ko.md`
→ 2건 (hook 테이블 + 프로젝트 구조)

TC-06: `grep -n "실행출력" README.ko.md`
→ line 81: TC + 개발 — 테이블 + 실행출력 형식
→ line 112: QA가 실행출력을 증거로 기록
→ line 113: 실행출력 증거가 없는 step은 hook이 차단
→ line 218: TC 테이블 + 구현 + 실행출력 증거
