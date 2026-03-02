# 개발 Phase 2: install.sh 변경

## 개발 범위

- 구현할 기능:
  - 기능 3: `install.sh` 228번 줄 `copy_file` 대상을 `dev-bounce.md`로 변경, 339번 줄 완료 메시지 반영
  - 기능 4: 설치 시 SCOPE에 따라 대상 CLAUDE.md에 `/dev-bounce` 강제 호출 규칙 관리 블록 주입
  - 기능 6(커밋 전략): 설치 시 커밋 전략 선택 프롬프트 + commit 스킬 감지 + `config.json` 저장 + `--config` 플래그 지원
  - 기능 7: `dev-bounce.md`에서 `[STEP:N:테스트통과]` 직후 `config.json` 커밋 전략 읽어 커밋 처리 흐름 추가
  - 기능 6(uninstall): `--uninstall` 시 CLAUDE.md 관리 블록 제거 로직 추가
- 관련 파일/컴포넌트:
  - `install.sh` (lines 228, 251-258, 334-348 + 신규 섹션)
  - `commands/dev-bounce.md` (Phase 3 커밋 전략 흐름 추가)
  - `~/.claude/ai-bouncer/config.json` (설치 시 생성/업데이트)

## Step 목록

- Step 1: install.sh copy_file 경로 및 완료 메시지 변경 (기능 3)
  - 완료 기준: `copy_file` 호출이 `dev-bounce.md` 대상으로 변경됨, 완료 메시지 `commands: dev-bounce.md (/dev-bounce)` 출력됨
- Step 2: CLAUDE.md 관리 블록 주입 로직 추가 (기능 4)
  - 완료 기준: global/local 설치 모두 대상 CLAUDE.md에 `# --- ai-bouncer-rule start ---` ~ `# --- ai-bouncer-rule end ---` 블록이 주입됨, 재설치 시 중복 없이 교체됨, CLAUDE.md 없는 환경에서 신규 생성됨
- Step 3: 커밋 전략 선택 + config.json 저장 + --config 플래그 (기능 6-커밋)
  - 완료 기준: 설치 시 `per-step`/`per-phase`/`none` 선택 프롬프트 출력, commit 스킬 감지 후 `commit_skill` boolean 저장, `config.json`에 `commit_strategy`/`commit_skill` 필드 저장됨, `bash install.sh --config` 실행 시 커밋 전략만 재선택 가능
- Step 4: dev-bounce.md에 커밋 전략 처리 흐름 추가 (기능 7)
  - 완료 기준: `[STEP:N:테스트통과]` 직후 `config.json` 읽어 `commit_strategy`에 따라 분기하는 흐름이 `dev-bounce.md` Phase 3 섹션에 명시됨, `commit_skill: true` 시 `/commit` 스킬 호출, `false` 시 `git commit` 직접 실행
- Step 5: uninstall 시 CLAUDE.md 블록 제거 (기능 6-uninstall)
  - 완료 기준: `--uninstall` 실행 시 CLAUDE.md에서 관리 블록 제거됨, 블록 없으면 no-op, CLAUDE.md 파일 자체는 삭제되지 않음, config.json에 `scope`/`target_dir` 저장되어 uninstall 시 경로 감지

## 이 Phase 완료 기준

- install.sh 실행 시 `commands/dev-bounce.md` 설치됨
- 설치 후 대상 CLAUDE.md에 ai-bouncer-rule 블록 존재
- config.json에 `docs_git_track`, `commit_strategy`, `commit_skill`, `scope`, `target_dir` 모두 저장됨
- `bash install.sh --config` 실행 시 커밋 전략만 재선택 가능
- `--uninstall` 실행 시 CLAUDE.md 블록 제거됨
- dev-bounce.md Phase 3에 커밋 전략 분기 흐름 존재
- 모든 Step의 `[STEP:N:테스트통과]` 확인됨
