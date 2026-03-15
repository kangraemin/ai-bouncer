# QA Check Report

> 점검일: 2026-03-15 점검
> 프로젝트: ai-bouncer
> 스택: Bash + Python (inline), Shell hooks

## 요약

| 카테고리 | Critical | Important | Minor |
|----------|----------|-----------|-------|
| 코드 로직 | 4 | 4 | 1 |
| 보안 | 1 | 1 | 0 |
| 설정/환경 | 0 | 1 | 0 |
| 의존성 | 0 | 0 | 0 |
| 코드 품질 | 0 | 0 | 2 |
| **합계** | **5** | **6** | **3** |

## 이전 QA 대비 변경

- [C-3] bash-gate `save_snapshot` sort 누락 → **수정됨** (line 271에 `| sort` 추가)
- [C-3] 대신 **새 Critical** 발견: snapshot 경로 불일치 (아래 C-3-NEW)

---

## Critical 이슈

### [C-1] bash-audit.sh ↔ bash-gate.sh: snapshot 경로 불일치 (Layer 2 무효화)
- **파일**: `hooks/bash-gate.sh:270`, `hooks/bash-audit.sh:13`
- **문제**: bash-gate.sh는 세션 격리 적용하여 `/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}`에 저장하는데, bash-audit.sh는 `/tmp/.ai-bouncer-snapshot` (고정 경로)에서 읽음
- **영향**: SESSION_ID가 설정된 모든 환경에서 bash-audit(Layer 2 자동 복원)이 작동하지 않음. snapshot 파일을 찾지 못해 항상 `exit 0`
- **수정 제안**: bash-audit.sh에서도 SESSION_ID 기반 경로 사용:
  ```bash
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
  SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}"
  ```

### [C-2] subagent-cleanup.sh: 비원자적 파일 업데이트로 데이터 손실 가능
- **파일**: `hooks/subagent-cleanup.sh:15-16`
- **문제**: `grep -v ... > $TEMP || true` + `mv $TEMP $APPROVED_FILE` — grep 실패 시 `|| true`로 빈 $TEMP 생성 후 mv로 덮어씀
- **영향**: 동시 sub-agent 종료 시 approved-agents 파일이 빈 파일로 교체 → 모든 승인 정보 손실
- **수정 제안**: grep 결과가 비어있으면 mv 전 체크, 또는 `sponge` 패턴

### [C-3] bash-gate.sh: jq max on null → "step-null.md" 경로 생성
- **파일**: `hooks/bash-gate.sh:148`
- **문제**: `.dev_phases["N"].steps`가 비어있을 때 `keys | map(tonumber) | max`가 `null` 반환 → `LAST_STEP_CS="null"` → `step-null.md` 경로
- **영향**: per-phase commit_strategy에서 무조건 block 또는 엉뚱한 파일 체크
- **수정 제안**: `jq -r '... | max // 0'` 또는 null 체크

### [C-4] install.sh: JSON heredoc에 변수 미이스케이프
- **파일**: `install.sh:493-502`
- **문제**: `cat > config.json << JSON` 안에서 `"$TARGET_DIR"` 삽입 — 경로에 `"` 포함 시 JSON 파손
- **영향**: config.json 파손 → 이후 모든 hook이 config 파싱 실패
- **수정 제안**: `jq -n --arg` 또는 Python으로 JSON 생성

### [C-5] install.sh: Python 내 인라인 경로 인용 취약
- **파일**: `install.sh:252`, `update.sh:57,63`
- **문제**: `python3 -c "... open('$CONFIG_FILE') ..."` — 경로에 `'` 포함 시 Python 구문 오류
- **영향**: 작은따옴표 포함 경로에서 install/update 실패
- **수정 제안**: `sys.argv`로 경로 전달 (install.sh 본체는 이미 이 패턴 사용, update.sh만 미적용)

## Important 이슈

### [I-1] bash-gate/plan-gate: 산술 비교 에러 억제 (`2>/dev/null`)
- **파일**: `hooks/bash-gate.sh:385,405`, `hooks/plan-gate.sh:123,142`
- **문제**: `[ "$MEMBER_COUNT" -lt 1 ] 2>/dev/null` — 비숫자 값일 때 에러 억제 → false → gate 통과
- **영향**: 팀 멤버/phase/step 검증 우회 가능
- **수정 제안**: `MEMBER_COUNT=${MEMBER_COUNT//[^0-9]/}; MEMBER_COUNT=${MEMBER_COUNT:-0}` 정제 후 비교

### [I-2] subagent-track.sh: glob 패턴에 `/` 누락
- **파일**: `hooks/subagent-track.sh:20`
- **문제**: `"$date_dir"*/.active` — for loop의 `date_dir`는 trailing `/` 포함(glob 확장)이지만, 명시적이지 않아 환경 의존
- **영향**: 특정 환경에서 .active 파일 탐색 실패 가능

### [I-3] subagent-track.sh: REPO_ROOT fallback 누락
- **파일**: `hooks/subagent-track.sh:13`
- **문제**: `REPO_ROOT=$(git rev-parse ... 2>/dev/null)` — git 외부 실행 시 빈 문자열. bash-gate.sh:355는 `|| echo "."` 있음
- **영향**: REPO_NAME 빈 값 → persistent 경로에 이중 슬래시

### [I-4] update.sh: realpath 비교 실패 시 복사 스킵
- **파일**: `update.sh:313-320`
- **문제**: 양쪽 파일 미존재 시 `realpath` 빈 문자열 → `"" != ""` false → 복사 스킵
- **영향**: update 실행 시 update.sh/uninstall.sh 프로젝트 루트 복사 누락 가능
- **수정 제안**: 대상 파일 존재 여부 먼저 체크

### [I-5] install.sh: manifest에 절대경로 혼입 가능
- **파일**: `install.sh:252`
- **문제**: Python 경로 변환 실패 시 `|| echo "$dst"` 폴백이 절대경로 반환 → uninstall이 잘못된 경로 참조
- **영향**: uninstall 불완전

### [I-6] 테스트: $HOME 직접 오염
- **파일**: `tests/test-bash-gate.sh:53-54`, `tests/test-plan-gate.sh:64-65`
- **문제**: 테스트가 실제 `$HOME/.claude/teams/`에 디렉토리 생성. 실패 시 cleanup 미실행
- **영향**: 사용자 환경에 잔류 파일

## Minor 이슈

### [M-1] bash-gate/plan-gate: 한국어 grep 로케일 의존
- **파일**: `hooks/bash-gate.sh:478`, `hooks/plan-gate.sh:272`
- **내용**: `grep -qE '(실행출력|실행 결과|출력:|Output:)'` — C/POSIX 로케일에서 한국어 매칭 실패 가능

### [M-2] BOUNCER_HOOKS 목록 다중 정의
- **파일**: `install.sh:140`, `uninstall.sh:117`
- **내용**: 훅 목록이 install/uninstall에 각각 하드코딩. hooks.json manifest가 있지만 uninstall은 미사용

### [M-3] install.sh TODO 주석
- **파일**: `install.sh:209`
- **내용**: `# TODO: 전역 설치 임시 비활성화` — 의도적 비활성화이므로 NOTE가 더 적절

## TODO/FIXME 목록

- `install.sh:209` — `# TODO: 전역 설치 임시 비활성화 — 로컬 전용`

## 점검하지 않은 영역

- agents/*.md 프롬프트 품질 (LLM 해석 의존)
- skills/dev-bounce/SKILL.md 워크플로우 정합성 전체 검증
- 외부 서비스 연동 (GitHub API 등)
- Claude Code hook 런타임 실제 동작
- 동시 세션에서의 state.json 파일 잠금 경쟁 조건
- docs/2026-03-14/ 미추적 디렉토리 내용
