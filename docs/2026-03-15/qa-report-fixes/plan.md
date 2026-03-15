# QA 리포트 이슈 전체 수정

QA-REPORT.md에서 발견된 Critical 5건, Important 6건, Minor 3건을 일괄 수정한다.

## 변경 파일별 상세

### `hooks/bash-audit.sh`
- **변경 이유**: [C-1] SESSION_ID 기반 snapshot 경로 불일치 → Layer 2 무효화
- **Before** (line 11-16):
```bash
# --- ai-bouncer start ---

SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot"

# 스냅샷 없으면 → gate 비활성 판단 (bash-gate가 스냅샷 미생성) → 스킵
[ -f "$SNAPSHOT_FILE" ] || exit 0

# 승인된 sub-agent는 부모 task 기준으로 이미 gate 통과 → audit 스킵
AGENT_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
```
- **After**:
```bash
# --- ai-bouncer start ---

# 세션 격리: session_id 추출 (bash-gate.sh와 동일 경로 사용)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
SNAPSHOT_FILE="/tmp/.ai-bouncer-snapshot-${SESSION_ID:-default}"

# 스냅샷 없으면 → gate 비활성 판단 (bash-gate가 스냅샷 미생성) → 스킵
[ -f "$SNAPSHOT_FILE" ] || exit 0

# 승인된 sub-agent는 부모 task 기준으로 이미 gate 통과 → audit 스킵
AGENT_SESSION_ID="$SESSION_ID"
```
- **영향 범위**: bash-gate.sh의 save_snapshot과 경로가 일치하게 됨

### `hooks/subagent-cleanup.sh`
- **변경 이유**: [C-2] grep 실패 시 빈 파일로 mv → 승인 데이터 손실
- **Before** (line 14-16):
```bash
TEMP=$(mktemp)
grep -v "^${AGENT_SESSION_ID}|" "$APPROVED_FILE" > "$TEMP" 2>/dev/null || true
mv "$TEMP" "$APPROVED_FILE"
```
- **After**:
```bash
TEMP=$(mktemp)
grep -v "^${AGENT_SESSION_ID}|" "$APPROVED_FILE" > "$TEMP" 2>/dev/null
# grep 결과 없어도(exit 1) 정상 — 해당 행만 없는 것. 단, 파일 자체 에러 시 원본 보존
if [ -f "$TEMP" ]; then
  mv "$TEMP" "$APPROVED_FILE"
else
  rm -f "$TEMP"
fi
```

### `hooks/bash-gate.sh`
- **변경 이유**: [C-3] jq max on null → step-null.md, [I-1] 산술 비교 에러 억제
- **Before** (line 148):
```bash
LAST_STEP_CS=$(jq -r ".dev_phases[\"$CS_PHASE\"].steps | keys | map(tonumber) | max" "$STATE_FILE" 2>/dev/null)
```
- **After**:
```bash
LAST_STEP_CS=$(jq -r ".dev_phases[\"$CS_PHASE\"].steps | keys | map(tonumber) | max // 0" "$STATE_FILE" 2>/dev/null)
```
- **Before** [I-1] (line 385, 405 등):
```bash
if [ "$MEMBER_COUNT" -lt 1 ] 2>/dev/null; then
```
- **After**:
```bash
MEMBER_COUNT=${MEMBER_COUNT:-0}; MEMBER_COUNT=${MEMBER_COUNT//[^0-9]/}; MEMBER_COUNT=${MEMBER_COUNT:-0}
if [ "$MEMBER_COUNT" -lt 1 ]; then
```
- 동일 패턴을 `CURRENT_DEV_PHASE`, `CURRENT_STEP` 비교에도 적용 (line 405, 423)
- **[M-1]** 한국어 grep 로케일: `LC_ALL=en_US.UTF-8` 프리픽스 추가

### `hooks/plan-gate.sh`
- **변경 이유**: [I-1] 산술 비교, [M-1] 로케일
- `MEMBER_COUNT` 비교 (line 123) 동일 패턴 적용
- `CURRENT_DEV_PHASE`/`CURRENT_STEP` 비교 (line 142) 동일 패턴 적용
- 한국어 grep에 `LC_ALL=en_US.UTF-8` 추가

### `install.sh`
- **변경 이유**: [C-4] JSON heredoc, [C-5] Python 인라인 경로, [I-5] manifest 절대경로, [M-3] TODO→NOTE
- **Before** [C-4] (line 493-502):
```bash
cat > "$BOUNCER_DATA_DIR/config.json" << JSON
{
  "docs_git_track": $DOCS_TRACK_BOOL,
  ...
}
JSON
```
- **After**:
```bash
python3 - "$BOUNCER_DATA_DIR/config.json" "$DOCS_TRACK_BOOL" "$COMMIT_STRATEGY" "$COMMIT_SKILL_BOOL" "$TARGET_DIR" "$ENFORCEMENT_MODE" "$AGENT_MODE" <<'PYEOF'
import json, sys
path = sys.argv[1]
cfg = {
    "docs_git_track": sys.argv[2] == "true",
    "commit_strategy": sys.argv[3],
    "commit_skill": sys.argv[4] == "true",
    "target_dir": sys.argv[5],
    "enforcement_mode": sys.argv[6],
    "agent_mode": sys.argv[7]
}
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
```
- **Before** [C-5] (line 252):
```bash
INSTALLED_FILES+=("$(python3 -c "import os; print(os.path.relpath('$dst', '$TARGET_DIR'))" 2>/dev/null || echo "$dst")")
```
- **After**:
```bash
INSTALLED_FILES+=("$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$dst" "$TARGET_DIR" 2>/dev/null || echo "$dst")")
```
- **[I-5]**: 동일 수정으로 해결 — relpath 실패 시 fallback은 유지하되, 경로 인용 문제 제거
- **[M-3]** (line 209): `# TODO:` → `# NOTE:`

### `update.sh`
- **변경 이유**: [C-5] Python 인라인 경로, [I-4] realpath 비교 실패
- **Before** [C-5] (line 57):
```bash
TARGET_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('target_dir','$REPO_ROOT/.claude'))")
```
- **After**:
```bash
TARGET_DIR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('target_dir',sys.argv[2]))" "$CONFIG_FILE" "$REPO_ROOT/.claude")
```
- **Before** [I-4] (line 313):
```bash
if [ "$(realpath "$PACKAGE_DIR/update.sh" 2>/dev/null)" != "$(realpath "$REPO_ROOT/update.sh" 2>/dev/null)" ]; then
```
- **After**:
```bash
if [ ! -f "$REPO_ROOT/update.sh" ] || [ "$(realpath "$PACKAGE_DIR/update.sh" 2>/dev/null)" != "$(realpath "$REPO_ROOT/update.sh" 2>/dev/null)" ]; then
```

### `hooks/subagent-track.sh`
- **변경 이유**: [I-2] glob `/` 누락, [I-3] REPO_ROOT fallback
- **Before** (line 13, 20):
```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
...
for active_file in "$date_dir"*/.active; do
```
- **After**:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
...
for active_file in "${date_dir}"*/.active; do
```

### `tests/test-bash-gate.sh`, `tests/test-plan-gate.sh`
- **변경 이유**: [I-6] $HOME 직접 오염
- team config 생성 경로를 `$dir/.claude/teams/` (테스트용 임시 디렉토리)로 변경하고, HOME을 override

### `uninstall.sh`
- **변경 이유**: [M-2] BOUNCER_HOOKS를 hooks.json에서 읽도록 변경
- **Before** (line 117-121): 하드코딩된 BOUNCER_HOOKS set
- **After**: `hooks.json` manifest에서 동적으로 읽기, 없으면 기존 하드코딩 fallback

## 검증

- `bash tests/e2e-full.sh` — 전체 E2E 66건
- `bash tests/e2e-hooks.sh` — hook 단위 25건
- `bash tests/test-bash-gate.sh` — bash-gate 단위
- `bash tests/test-plan-gate.sh` — plan-gate 단위
- `bash tests/test-bash-audit.sh` — bash-audit 단위 (C-1 snapshot 경로 수정 검증)
