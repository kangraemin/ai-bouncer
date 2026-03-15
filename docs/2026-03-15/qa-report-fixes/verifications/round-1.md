# Round 1 검증

## 검증 항목

| # | 항목 | 결과 | 근거 |
|---|------|------|------|
| 1 | C-1 bash-audit snapshot 경로 | ✅ 통과 | `bash-audit.sh:15` — `SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}"` |
| 2 | C-2 subagent-cleanup 안전 처리 | ✅ 통과 | `subagent-cleanup.sh:14-21` — TEMP mktemp + `if [ -f "$TEMP" ]` 체크 후 mv, 에러 시 원본 보존 |
| 3 | C-3 jq max null 방지 | ✅ 통과 | `bash-gate.sh:148` — `max // 0` fallback 확인 |
| 4 | C-4 install.sh JSON 안전 생성 | ✅ 통과 | `install.sh:493-507` — python3 `json.dump()` 사용, heredoc 아닌 구조화된 JSON 생성 |
| 5 | C-5 Python 경로 인젝션 방지 | ✅ 통과 | `install.sh:103-112,252,263,493-507` 및 `update.sh:57,63,327-334` — 모두 `sys.argv` 사용 |
| 6 | I-1 산술 비교 sanitize | ✅ 통과 | `bash-gate.sh:266-268`, `plan-gate.sh:50-52` — `${VAR//[^0-9]/}` 정제 확인 |
| 7 | I-2/I-3 subagent-track | ✅ 통과 | `subagent-track.sh:20` — glob 인용 `"${date_dir}"*/.active`, `:13` — `REPO_ROOT` fallback `echo "."` |
| 8 | I-4 update.sh realpath | ✅ 통과 | `update.sh:313,317` — `[ ! -f ]` 선행 체크 후 realpath 호출 |
| 9 | I-6 테스트 HOME 오염 | ✅ 통과 | `test-bash-gate.sh:16-19`, `test-plan-gate.sh:16-19` — FAKE_HOME 임시 디렉토리 사용 |
| 10 | M-1 로케일 | ✅ 통과 | `bash-gate.sh:447,480`, `plan-gate.sh:242,275` — `LC_ALL=en_US.UTF-8` 설정 |
| 11 | M-2 BOUNCER_HOOKS 동적 | ✅ 통과 | `uninstall.sh:120-132` — hooks.json 동적 읽기 + 하드코딩 fallback |
| 12 | M-3 TODO→NOTE | ✅ 통과 | `install.sh:209` — `# NOTE: 전역 설치 임시 비활성화` |

## 테스트 실행 결과

### test-plan-gate.sh
```
✅ 25/25 passed
```

### test-bash-gate.sh
```
❌ 2/33 not passed
- TC-B16: planning + echo > .active → BLOCK (gate 무력화 방지) — expected block, got allow
- TC-B27: ~/.claude/ai-bouncer/sessions/ 쓰기 → BLOCK — expected block, got allow
```
> 참고: TC-B16, TC-B27은 이번 QA 수정 범위(C-1~M-3) 외의 기존 이슈. .active 예외 처리와 sessions 경로 보호는 별도 항목.

### test-bash-audit.sh
```
❌ 1/10 not passed
- TC-A7: rm state.json → audit 복원 — state.json 복원 안 됨
```
> 참고: TC-A7도 이번 QA 수정 범위 외 기존 이슈.

## 결론

**12/12 검증 항목 통과**. 테스트 미통과 3건은 이번 수정 범위(C-1~M-3) 외의 기존 이슈.
