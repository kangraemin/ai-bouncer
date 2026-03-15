| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | skills/update-bouncer/SKILL.md 파일 존재 | 파일이 존재하고 description, 플로우 섹션 포함 | ✅ |
| TC-02 | install.sh에 동적 스킬 설치 로직 | skills/*/ 루프로 모든 스킬 설치 | ✅ |
| TC-03 | update.sh에 동적 스킬 복사 로직 | skills/*/ 디렉토리 루프로 모든 스킬 복사 | ✅ |
| TC-04 | E2E 테스트 통과 | bash tests/e2e-full.sh 전체 통과 | ✅ |

## 실행출력

TC-01: cat skills/update-bouncer/SKILL.md | head -3 && grep -c "플로우" skills/update-bouncer/SKILL.md
→ description: ai-bouncer 최신 버전 확인 및 업데이트 / 1 (플로우 섹션 존재)

TC-02: grep -A2 "skills.*동적" install.sh
→ for skill_src in "$PACKAGE_DIR/skills"/*/; do (동적 루프 확인)

TC-03: grep -A2 "skills.*동적" update.sh
→ for skill_dir in "$PACKAGE_DIR/skills"/*/; do (동적 루프 확인)

TC-04: bash tests/e2e-full.sh
→ 결과: ✅ 74 통과 / ❌ 0 실패
