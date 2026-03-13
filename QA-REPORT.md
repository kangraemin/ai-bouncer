# QA Check Report

> 점검일: 2026-03-13 14:30
> 프로젝트: ai-bouncer
> 스택: Bash + Python (inline), Shell hooks

## 요약

| 카테고리 | Critical | Important | Minor |
|----------|----------|-----------|-------|
| 코드 로직 | 4 | 5 | 2 |
| 보안 | 1 | 0 | 0 |
| 설정/환경 | 0 | 1 | 0 |
| 의존성 | 0 | 0 | 0 |
| 코드 품질 | 0 | 1 | 1 |
| **합계** | **5** | **7** | **3** |

## Critical 이슈

### [C-1] subagent-cleanup.sh: 비원자적 파일 업데이트로 데이터 손실 가능
- **파일**: `hooks/subagent-cleanup.sh:15-16`
- **문제**: `grep -v ... > $TEMP || true` + `mv $TEMP $APPROVED_FILE` — grep 실패(파일 없음 등) 시 `|| true`로 빈 $TEMP 생성 후 mv로 덮어씌움
- **영향**: 동시 실행 시 approved-agents 파일이 빈 파일로 교체되어 모든 승인 정보 손실
- **수정 제안**: `grep` 결과가 비어있으면 mv 스킵, 또는 `sponge` 패턴 사용

### [C-2] bash-gate.sh: jq max on null → "step-null.md" 파일 참조
- **파일**: `hooks/bash-gate.sh:142`
- **문제**: `.dev_phases["N"].steps`가 없거나 비어있을 때 `keys | map(tonumber) | max`가 `null` 반환 → `LAST_STEP_CS="null"` → `step-null.md` 경로 생성
- **영향**: per-phase commit_strategy에서 무조건 block되거나 엉뚱한 파일 체크
- **수정 제안**: `jq -r '... | max // 0'` 또는 null 체크 추가

### [C-3] bash-audit.sh: comm 입력 정렬 불일치
- **파일**: `hooks/bash-audit.sh:30-33`, `hooks/bash-gate.sh:265`
- **문제**: bash-audit.sh는 `CURRENT_STATE`를 `sort`하지만, bash-gate.sh의 `save_snapshot`은 정렬 없이 저장. `comm -13`은 정렬된 입력 필수.
- **영향**: 비인가 파일 탐지가 누락되거나 오탐 발생
- **수정 제안**: `save_snapshot()`에서 `| sort` 추가

### [C-4] install.sh: Python 내 경로 미인용으로 특수문자 시 파손
- **파일**: `install.sh:253, 264, 321`, `update.sh:38-44`
- **문제**: `python3 -c "... open('$CONFIG_FILE') ..."` — 경로에 작은따옴표 포함 시 Python 구문 오류
- **영향**: 작은따옴표 포함 경로에서 install/update 실패, TARGET_DIR 빈 값으로 후속 작업 파손
- **수정 제안**: Python에 환경변수로 전달하거나 `sys.argv` 사용

### [C-5] install.sh: JSON heredoc에 변수 미이스케이프
- **파일**: `install.sh:500-509`
- **문제**: `cat > config.json << JSON` 안에서 `"$TARGET_DIR"` 등이 그대로 삽입 — 경로에 `"` 포함 시 JSON 깨짐
- **영향**: config.json 파손 → 이후 모든 hook이 config 파싱 실패
- **수정 제안**: `jq -n --arg` 또는 Python으로 JSON 생성

## Important 이슈

### [I-1] bash-gate.sh: 산술 비교 에러 억제 (`2>/dev/null` 위치)
- **파일**: `hooks/bash-gate.sh:378, 391`, `hooks/plan-gate.sh:122, 134`
- **문제**: `[ "$MEMBER_COUNT" -lt 1 ] 2>/dev/null` — 비숫자 값일 때 에러가 억제되어 조건이 false 반환 → gate가 차단하지 않고 통과
- **영향**: 팀 멤버 검증, phase/step 검증이 우회될 수 있음
- **수정 제안**: 먼저 숫자 검증 후 비교, 또는 기본값 할당

### [I-2] subagent-track.sh: glob 패턴에 `/` 누락
- **파일**: `hooks/subagent-track.sh:20`
- **문제**: `for active_file in "$date_dir"*/.active` — `$date_dir`와 `*` 사이 `/` 누락
- **영향**: date_dir에 trailing `/`가 없으면 잘못된 패턴으로 .active 파일 탐색 실패
- **수정 제안**: `"$date_dir"/*/.active`

### [I-3] subagent-track.sh: REPO_ROOT 폴백 누락
- **파일**: `hooks/subagent-track.sh:13`
- **문제**: `REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)` — git 외부에서 실행 시 빈 문자열. bash-gate.sh:349는 `|| echo "."` 폴백 있음
- **영향**: REPO_NAME 빈 값 → 세션 경로 이중 슬래시

### [I-4] update.sh: realpath 비교 실패 시 복사 스킵
- **파일**: `update.sh:262-272`
- **문제**: 파일 미존재 시 `realpath` 양쪽 다 빈 문자열 반환 → `"" != ""` false → 복사 스킵
- **영향**: 첫 update 실행 시 update.sh/uninstall.sh가 복사되지 않을 수 있음
- **수정 제안**: 파일 존재 여부 먼저 체크

### [I-5] install.sh: manifest에 절대경로 혼입 가능
- **파일**: `install.sh:253, 704-722`
- **문제**: Python 경로 변환 실패 시 `|| echo "$dst"` 폴백이 절대경로 반환. manifest.json에 절대경로 저장 → uninstall.sh가 잘못된 경로로 파일 삭제 시도
- **영향**: uninstall 불완전

### [I-6] uninstall.sh: manifest 읽기 실패를 성공으로 처리
- **파일**: `uninstall.sh:45-68`
- **문제**: `sys.exit(0)` — manifest 파싱 실패 시 Python이 성공 코드 반환. 설정은 정리되지만 파일은 남음
- **영향**: 불완전한 uninstall (파일 잔류 + 설정 정리 = 불일치 상태)

### [I-7] 테스트: $HOME 직접 오염
- **파일**: `tests/test-bash-gate.sh:53-54`, `tests/test-plan-gate.sh:64-65`, `tests/e2e-hooks.sh:83-84`
- **문제**: 테스트가 실제 `$HOME/.claude/teams/`에 디렉토리 생성. 테스트 실패 시 cleanup 미실행 → 잔류 파일
- **영향**: 사용자 환경 오염, 테스트 간 간섭
- **수정 제안**: FAKE_HOME 사용 또는 trap으로 cleanup 보장

## Minor 이슈

### [M-1] bash-gate.sh: 한국어 regex 로케일 의존
- **파일**: `hooks/bash-gate.sh:464`, `hooks/plan-gate.sh:264`
- **문제**: `grep -qE '(실행출력|실행 결과|출력:|Output:)'` — C/POSIX 로케일에서 한국어 매칭 실패 가능
- **수정 제안**: `LANG=ko_KR.UTF-8 grep` 또는 영어 패턴만 사용

### [M-2] BOUNCER_HOOKS 목록 3곳 분산 정의
- **파일**: `install.sh:141-142`, `uninstall.sh:117-121`, `update.sh`
- **문제**: 훅 목록이 3곳에 별도 정의 → 훅 추가/삭제 시 누락 위험
- **수정 제안**: 단일 소스(예: manifest 또는 공유 파일)에서 읽기

### [M-3] install.sh TODO 주석
- **파일**: `install.sh:210`
- **내용**: `# TODO: 전역 설치 임시 비활성화 — 로컬 전용` — NOTE가 더 적절

## TODO/FIXME 목록

- `install.sh:210` — `# TODO: 전역 설치 임시 비활성화 — 로컬 전용`

## 점검하지 않은 영역

- agents/*.md 프롬프트 품질 (LLM 해석 의존)
- skills/dev-bounce/SKILL.md 워크플로우 정합성
- 외부 서비스 연동 (GitHub API, Notion 등)
- Claude Code hook 런타임 동작 (실제 환경 필요)
- 동시 세션에서의 state.json 경쟁 조건 (파일 잠금 없음)
