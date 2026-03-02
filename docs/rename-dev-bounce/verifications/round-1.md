# 검증 1회차

## Plan 대비 구현 확인

- 기능 1 (commands/dev.md → dev-bounce.md 파일 rename): ✅
  - `commands/dev-bounce.md` 존재 확인
  - `commands/dev.md` 삭제 확인 (commands/ 에 dev-bounce.md만 존재)
- 기능 2 (파일 내 커맨드명 변경): ✅
  - Line 5 = `# /dev-bounce` 확인
  - frontmatter description = `/dev-bounce — 구조화된 개발 flow 실행 (ai-bouncer v4)` 확인
- 기능 3 (install.sh copy_file 경로 반영): ✅
  - `copy_file "$PACKAGE_DIR/commands/dev-bounce.md" "$TARGET_DIR/commands/dev-bounce.md"` (line 309) 존재
  - `dev.md (/dev)` 참조 없음
  - 완료 메시지 `commands: dev-bounce.md (/dev-bounce)` (line 490) 존재
- 기능 4 (install.sh CLAUDE.md 자동 주입): ✅
  - `# --- ai-bouncer-rule start ---` / `# --- ai-bouncer-rule end ---` 마커 (line 381~382) 존재
  - 주입 내용에 `/dev-bounce 스킬을 먼저 호출` (line 387) 포함
  - 파일 설치(line 215) < CLAUDE.md 주입(line 370~) < settings.json 설정(line 401~) 순서 확인
  - 기존 블록 교체 분기 (`s != -1 and e != -1`, line 283) 존재
  - 신규 생성 분기 (`os.path.exists` 조건 불충족 시, line 291) 존재
- 기능 5 (dev-bounce.md Phase 1 plan mode 활용): ✅
  - Phase 1 진입 직후 `### 1-0. Plan Mode 진입` + `EnterPlanMode 호출` (line 41) 존재
  - streak>=3 후 `[PLAN:승인대기]` 표시 → `ExitPlanMode 호출` (line 121) 존재
  - 수정 요청 시 `EnterPlanMode 재진입` (line 129) 명시
- 기능 6 (install.sh 커밋 전략 설정): ✅
  - per-step/per-phase/none 3가지 옵션 UI (line 336~338, 152~154) 존재
  - commit.md 파일 존재 여부로 COMMIT_SKILL_BOOL 감지 (line 166~169, 350~354) 존재
  - `--config` 플래그 분기 (line 143~) 존재
  - config.json에 `commit_strategy`, `commit_skill`, `target_dir` (line 363~366) 저장
- 기능 7 (dev-bounce.md Phase 3 커밋 전략 처리): ✅
  - Phase 3 `### 3-4. Step/Phase 완료 시 커밋` 섹션에 `commit_strategy` 읽기 (line 200, 204) 존재
  - per-step/per-phase/none × commit_skill true/false 테이블 (line 204~210) 존재
  - 커밋 실패 시 다음 Step 진행 금지 명시
- 기능 8 (--uninstall CLAUDE.md 블록 제거): ✅
  - `--uninstall` 섹션 내 `config.json`에서 `target_dir` 읽어 CLAUDE_FILE 경로 결정 (line 100~102) 존재
  - 마커 블록 제거 후 나머지 내용 보존 로직 (line 120~122) 존재
  - 블록 없으면 no-op `sys.exit(0)` (line 116~117) 존재
  - `bash -n install.sh` 문법 오류 없음

---

## 문서 완결성

| 파일 | TC | 빌드 | 완료기준 |
|---|---|---|---|
| phase-1-commands/step-1.md | ✅ (TC-1~3 실제 결과 채워짐) | ✅ (git mv 실행) | ✅ |
| phase-1-commands/step-2.md | ✅ (TC-1~5 실제 결과 채워짐) | ✅ (검증 명령어 성공) | ✅ |
| phase-1-commands/step-3.md | ✅ (TC-1~5 실제 결과 채워짐) | ✅ (grep 확인) | ✅ |
| phase-2-install/step-1.md | ✅ (TC-1~4 실제 결과 채워짐) | ✅ (bash -n SYNTAX OK) | ✅ |
| phase-2-install/step-2.md | ✅ (TC-1~6 실제 결과 채워짐) | ✅ (bash -n SYNTAX OK) | ✅ |
| phase-2-install/step-3.md | ✅ (TC-1~6 실제 결과 채워짐) | ✅ (bash -n SYNTAX OK) | ✅ |
| phase-2-install/step-4.md | ✅ (TC-1~5 실제 결과 채워짐) | ✅ (grep 확인) | ✅ |
| phase-2-install/step-5.md | ✅ (TC-1~5 실제 결과 채워짐) | ✅ (bash -n exit code 0) | ✅ |

---

## 테스트 결과

- 명령어: 직접 검증 (grep, bash -n, sed, python3 인라인)
- Feature 1: `ls commands/ | grep dev` → `dev-bounce.md` 만 존재
- Feature 2: `sed -n '5p' commands/dev-bounce.md` → `# /dev-bounce`; description 확인
- Feature 3: `grep -n "copy_file.*dev" install.sh` → line 309 dev-bounce.md; line 490 완료 메시지
- Feature 4: `grep -n "ai-bouncer-rule" install.sh` → line 381~382, 385~388
- Feature 5: `grep -n "EnterPlanMode\|ExitPlanMode" commands/dev-bounce.md` → 2/1회 확인
- Feature 6: `grep -n "per-step\|commit_strategy\|--config" install.sh` → 전부 존재
- Feature 7: `sed -n '195,215p' commands/dev-bounce.md` → 커밋 전략 테이블 존재
- Feature 8: `sed -n '80,145p' install.sh` → uninstall CLAUDE.md 블록 제거 로직 존재
- bash 문법 검사: `bash -n install.sh` → SYNTAX OK
- 결과: 8/8 기능 통과

---

## 결론

통과. 8개 기능 모두 구현 확인. 모든 step 문서 TC 결과 채워짐. install.sh 문법 오류 없음.
