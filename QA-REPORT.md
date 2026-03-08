# QA Check Report

> 점검일: 2026-03-08 21:40
> 프로젝트: ai-bouncer
> 스택: Bash + Python (inline), Shell hooks

## 요약

| 카테고리 | Critical | Important | Minor |
|----------|----------|-----------|-------|
| 코드 로직 | 2 | 1 | 0 |
| 보안 | 0 | 0 | 0 |
| 설정/환경 | 0 | 1 | 1 |
| 의존성 | 0 | 0 | 0 |
| 코드 품질 | 0 | 1 | 0 |
| **합계** | **2** | **3** | **1** |

## Critical 이슈

### [C-1] update.sh: 모든 경로가 글로벌($HOME/.claude/)로 하드코딩
- **파일**: `update.sh:17,43,113-114`
- **문제**: install.sh는 로컬 `.claude/`에 설치하지만, update.sh는 `$HOME/.claude/`(글로벌)에서 config/manifest를 찾고 skill을 글로벌에 설치
  ```bash
  CONFIG_FILE="$HOME/.claude/ai-bouncer/config.json"  # L17 — 로컬이어야 함
  SKILL_DST="$HOME/.claude/skills/dev-bounce"          # L43 — 로컬이어야 함
  MANIFEST="$HOME/.claude/ai-bouncer/manifest.json"    # L113 — 로컬이어야 함
  ```
- **영향**: 로컬 설치 후 `update.sh` 실행 시 config를 못 찾아 에러 발생. skill이 글로벌에 중복 설치됨.
- **수정 제안**: install.sh와 동일하게 `git rev-parse --show-toplevel`로 로컬 `.claude/` 경로 사용

### [C-2] update.sh: subagent hooks 업데이트 누락
- **파일**: `update.sh:100-104`
- **문제**: install.sh는 `subagent-track.sh`, `subagent-cleanup.sh`를 설치하지만, update.sh는 이 두 파일을 업데이트하지 않음
- **영향**: update 후에도 이전 버전의 subagent hooks 유지. 버그 수정이 반영되지 않음.
- **수정 제안**: update.sh에 subagent hooks copy + chmod 추가

## Important 이슈

### [I-1] e2e-hooks.sh: 세션 격리 수정 후 snapshot 테스트 호환성
- **파일**: `tests/e2e-hooks.sh:30,201,206,231`
- **문제**: bash-audit.sh가 세션 격리된 snapshot(`/tmp/.ai-bouncer-snapshot-${SESSION_ID}`)을 사용하도록 수정되었지만, e2e-hooks.sh는 여전히 `/tmp/.ai-bouncer-snapshot`(비격리) 파일을 생성/정리
  ```bash
  rm -f /tmp/.ai-bouncer-approved-agents /tmp/.ai-bouncer-snapshot  # L30 — 세션 격리 파일명 아님
  touch /tmp/.ai-bouncer-snapshot  # L206 — audit가 이 파일을 못 찾음
  ```
- **영향**: bash-audit 테스트가 실제로 snapshot을 감지하지 못할 수 있음 (현재는 "스킵" 경로로 우회되어 통과)
- **수정 제안**: `TEST_SID` 기반 snapshot 파일명 사용: `/tmp/.ai-bouncer-snapshot-${TEST_SID}`

### [I-2] .gitignore 파일 없음
- **파일**: 프로젝트 루트
- **문제**: .gitignore가 없어 `.claude/`(설치된 파일), `.idea/`(IDE), `HANDOFF.md`, `.worklogs/`가 git status에 표시됨
- **영향**: 실수로 설치된 파일이나 IDE 설정이 커밋될 수 있음
- **수정 제안**: `.gitignore` 추가:
  ```
  .claude/
  .idea/
  .worklogs/
  HANDOFF.md
  ```

### [I-3] e2e-hooks.sh: subagent-track planning 테스트 환경 간섭
- **파일**: `tests/e2e-hooks.sh:166-175`
- **문제**: subagent-track.sh가 프로젝트 전체의 `.active` 파일을 스캔하므로, 다른 development 상태 task가 있으면 planning 테스트가 실패
- **영향**: 테스트가 독립적이지 않음 — 프로젝트에 활성 task가 있으면 항상 실패
- **수정 제안**: 테스트 시작 시 다른 `.active` 파일을 임시 이동하거나, e2e-full.sh처럼 임시 git repo에서 실행

## Minor 이슈

### [M-1] install.sh TODO 주석
- **파일**: `install.sh:93`
- **내용**: `# TODO: 전역 설치 임시 비활성화 — 로컬 전용` — 의도적 비활성화이므로 TODO보다 NOTE가 적절

## TODO/FIXME 목록

- `install.sh:93` — `# TODO: 전역 설치 임시 비활성화 — 로컬 전용`

## 점검하지 않은 영역

- agents/*.md 마크다운 내용의 논리적 정확성 (프롬프트 품질)
- skills/dev-bounce/SKILL.md 워크플로우 지시사항 (별도 세션에서 이미 점검 완료)
- 외부 서비스 연동 (GitHub API, Notion 등)
- Claude Code hook 런타임 동작 (실제 Claude Code 환경에서만 검증 가능)
