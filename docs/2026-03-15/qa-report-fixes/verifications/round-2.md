# Round 2 검증

## 검증 항목

| # | 항목 | 결과 | 근거 |
|---|------|------|------|
| 1 | C-1 bash-audit snapshot 경로 | ✅ 통과 | `bash-audit.sh:15` — `SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}"` |
| 2 | C-2 subagent-cleanup 안전 처리 | ✅ 통과 | `subagent-cleanup.sh:17` — `if [ -f "$TEMP" ]` 체크 후 mv, 미통과 시 원본 보존 |
| 3 | C-3 jq max null 방지 | ✅ 통과 | `bash-gate.sh:148` — `max // 0` fallback |
| 4 | C-4 install.sh JSON 안전 생성 | ✅ 통과 | `install.sh:123,200,505,616,716` — 5개소 모두 `json.dump()` 사용 |
| 5 | C-5 Python 경로 인젝션 방지 | ✅ 통과 | `install.sh` 15개소, `update.sh` 11개소 — 전부 `sys.argv` 경유 |
| 6 | I-1 산술 비교 sanitize | ✅ 통과 | `bash-gate.sh:266,268,386`, `plan-gate.sh:50,52,124,153` — `${VAR//[^0-9]/}` 정제 |
| 7 | I-2/I-3 subagent-track | ✅ 통과 | `subagent-track.sh:20` — glob 인용, `:13` — REPO_ROOT fallback `echo "."` |
| 8 | I-4 update.sh realpath | ✅ 통과 | `update.sh:313,317` — `[ ! -f ]` 선행 체크 |
| 9 | I-6 테스트 HOME 오염 | ✅ 통과 | `test-bash-gate.sh:16-19`, `test-plan-gate.sh:16-19` — FAKE_HOME 사용 |
| 10 | M-1 로케일 | ✅ 통과 | `bash-gate.sh:447,480`, `plan-gate.sh:242,275` — 4개소 `LC_ALL=en_US.UTF-8` |
| 11 | M-2 BOUNCER_HOOKS 동적 | ✅ 통과 | `uninstall.sh:119-132` — hooks.json 동적 읽기 + set fallback |
| 12 | M-3 TODO→NOTE | ✅ 통과 | `install.sh:209` — `# NOTE: 전역 설치 임시 비활성화` |

## 테스트 실행 결과

### test-plan-gate.sh
```
✅ 25/25 passed
```

### test-bash-gate.sh
```
❌ 2/33 not passed (TC-B16, TC-B27 — 기존 이슈, QA 수정 범위 외)
31/33 passed
```

### test-bash-audit.sh
```
❌ 1/10 not passed (TC-A7 — 기존 이슈, QA 수정 범위 외)
9/10 passed
```

## 결론

**12/12 검증 항목 통과**. 테스트 결과 Round 1과 동일 — 미통과 3건은 이번 수정 범위 외.
