# QA Check Report

> 점검일: 2026-03-16
> 프로젝트: ai-bouncer
> 스택: Bash Shell Scripts

## 요약

| 카테고리 | Critical | Important | Minor |
|----------|----------|-----------|-------|
| 코드 로직 | 1 | 4 | 1 |
| 보안 | 0 | 1 | 0 |
| 설정/환경 | 0 | 1 | 1 |
| 의존성 | 0 | 1 | 0 |
| 코드 품질 | 0 | 0 | 3 |
| **합계** | **1** | **7** | **5** |

> ℹ️ 초기 자동 QA에서 Critical 7건 보고 → 수동 검증 후 허위경보 5건 제거 (C-3 jq null, C-7 glob 패턴 등).

---

## Critical 이슈

### [C-1] subagent-cleanup.sh: 동시 종료 시 race condition으로 approved-agents 손실

- **파일**: `hooks/subagent-cleanup.sh:14-21`
- **문제**: `mktemp`는 항상 파일 생성 → `[ -f "$TEMP" ]` 항상 true. 두 sub-agent가 동시 종료 시 후발 `mv`가 선발 결과를 덮어써서 session_id 누락.
- **영향**: 동시 SubagentStop 이벤트 시 approved-agents 일부 손실 → sub-agent gate 오작동. 발생 확률 낮음.
- **수정 제안**:
  ```bash
  (
    flock -x 200
    TEMP=$(mktemp)
    grep -v "^${AGENT_SESSION_ID}|" "$APPROVED_FILE" > "$TEMP" 2>/dev/null || true
    mv "$TEMP" "$APPROVED_FILE"
  ) 200>"${APPROVED_FILE}.lock"
  ```

---

## Important 이슈

### [I-1] bash-gate.sh: fd>2 redirect 미탐지 (false negative)

- **파일**: `hooks/bash-gate.sh:22`
- **문제**: sed 패턴 `s/[0-9]+>[&]?[0-9]*//g`이 `3>/tmp/log.txt`의 `3>`를 제거해서 `>[^>&]` 패턴 매칭 실패 → IS_WRITE=false로 파일 쓰기 미탐지.
- **영향**: `3>/tmp/log.txt` 같은 fd3 리다이렉트로 파일 쓰기 시도가 gate 통과. 빈도 낮음.
- **수정 제안**: sed 패턴을 `[0-9]+>[&][0-9]+`(반드시 `&`+숫자)로 한정해 fd→파일 리다이렉트는 유지.

### [I-2] bash-gate.sh: verification 이후 agent_mode 검증 BLOCK에서 save_snapshot 누락

- **파일**: `hooks/bash-gate.sh` (agent_mode 검증 블록)
- **문제**: agent_mode 검증 각 BLOCK 분기에 `save_snapshot()` 미호출.
- **영향**: bash-audit.sh가 snapshot 없이 무단 변경 감지 불가.
- **수정 제안**: 각 BLOCK exit 직전에 `save_snapshot` 추가.

### [I-3] plan-gate.sh: TC 검증 정규식 느슨

- **파일**: `hooks/plan-gate.sh:319-326`
- **문제**: `[^ |]` (1자)로 TC 내용 확인. 공백만 있는 셀도 통과 가능.
- **수정 제안**: `[^ |]+` (1개 이상)으로 변경.

### [I-4] update.sh: realpath 미설치 시 파일 복사 스킵

- **파일**: `update.sh:333-340`
- **문제**: `realpath` 없으면 `"" != ""` false → update.sh/uninstall.sh 갱신 누락.
- **수정 제안**: `cmp -s`로 대체.

### [I-5] tests/: $HOME 직접 오염

- **파일**: `tests/test-bash-gate.sh:53`, `tests/test-plan-gate.sh:64`
- **문제**: 실제 `$HOME/.claude/`에 테스트 파일 생성. 실패 시 cleanup 미실행.
- **수정 제안**: `TEST_HOME=$(mktemp -d); trap 'rm -rf "$TEST_HOME"' EXIT; HOME="$TEST_HOME"` 패턴 적용.

### [I-6] install.sh: manifest에 절대경로 혼입 가능성

- **파일**: `install.sh:252`
- **문제**: `os.path.relpath()` 실패 시 절대경로 fallback → uninstall 오작동.
- **수정 제안**: 실패 시 빈 문자열 처리.

### [I-7] jq 설치 여부 미확인

- **파일**: 전체 hooks
- **문제**: 모든 hook이 `jq` 의존하지만 install 시 설치 확인 없음. jq 미설치 시 모든 hook 무음 실패.
- **수정 제안**: install.sh 초반에 `command -v jq >/dev/null 2>&1 || { echo "ERROR: jq 필요"; exit 1; }` 추가.

---

## Minor 이슈

### [M-1] bash-gate.sh: 쓰기 감지 정규식 가독성

- **파일**: `hooks/bash-gate.sh:23`
- **내용**: 단일 라인 18개 대안. 유지보수 시 패턴 누락 위험.

### [M-2] install.sh: 같은 날 재설치 시 백업 덮어쓰기

- **파일**: `install.sh:248`
- **내용**: `DATE_TAG=$(date +%Y%m%d)` — 하루 내 재설치 시 이전 백업 덮어씀. `%Y%m%d-%H%M%S` 권장.

### [M-3] bash-gate.sh/plan-gate.sh: 검증 로직 ~300줄 중복

- **파일**: `hooks/bash-gate.sh`, `hooks/plan-gate.sh`
- **내용**: CHECK 1-7 로직 거의 동일 반복. 한쪽 수정 시 다른 쪽 누락 위험.

### [M-4] doc-reminder.sh: block 후 exit 0 누락

- **파일**: `hooks/doc-reminder.sh:44-50`
- **내용**: `jq -n '{decision:"block",...}'` 출력 후 `exit 0` 없어서 block 결정 무시 가능.

### [M-5] hooks 목록 3곳 중복 정의

- **파일**: `install.sh:140`, `uninstall.sh:128`, `hooks/hooks.json`
- **내용**: 새 hook 추가 시 3곳 모두 업데이트 필요. 불일치 시 hook 누락.

---

## TODO/FIXME 목록

해당 없음

---

## 점검하지 않은 영역

- 외부 서비스 연동 (Notion API 등 — 인증 정보 필요)
- 실제 Claude Code hook 이벤트 통합 (런타임 환경 필요)
- macOS 이외 OS 호환성 (Linux, Windows WSL)
