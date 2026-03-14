| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | update.sh에 copy_if_changed 헬퍼 존재 | 함수 정의 확인 | ✅ |
| TC-02 | 변경 없는 파일 dim 표시 | `bash update.sh` 실행 시 `·` 표시 | ✅ |
| TC-03 | 마지막 요약 출력 | `N개 업데이트, M개 변경 없음` 형태 | ✅ |
| TC-04 | SKILL.md ExitPlanMode 흐름 복원 | "텍스트로 사용자에게 출력" + "ExitPlanMode 호출" 문구 존재 | ✅ |
| TC-05 | 소스↔설치본 동기화 | diff 결과 없음 | ✅ |

## 실행출력

TC-01: grep "copy_if_changed" update.sh | head -1
→ `copy_if_changed() {`

TC-02: bash update.sh → 변경 없는 파일 17개 `·` 표시 확인

TC-03: bash update.sh → `1개 업데이트, 17개 변경 없음` 출력 확인

TC-04: grep "텍스트로 사용자에게 출력" skills/dev-bounce/SKILL.md
→ 2건 매칭 (SIMPLE + NORMAL)
grep "ExitPlanMode 호출" skills/dev-bounce/SKILL.md
→ 2건 매칭

TC-05: diff <(sed -n '5,$p' skills/dev-bounce/SKILL.md) <(sed -n '5,$p' .claude/skills/dev-bounce/SKILL.md)
→ 출력 없음 (일치)
