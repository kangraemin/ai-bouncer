#!/bin/bash
# ai-bouncer 자동 업데이트 체커
# Usage: bouncer-update-check.sh [--force] [--check-only]
#   --force      : 24h throttle 무시하고 즉시 체크
#   --check-only : 버전 확인만 (업데이트 안 함)

set -euo pipefail

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python3)

REPO="${AI_BOUNCER_REPO:-kangraemin/ai-bouncer}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"
API_URL="https://api.github.com/repos/$REPO/commits/main"

# ── 옵션 파싱 ──────────────────────────────────────────────────────────────────
FORCE=false
CHECK_ONLY=false
HEALTH=false
for arg in "$@"; do
  case $arg in
    --force)      FORCE=true ;;
    --check-only) CHECK_ONLY=true ;;
    --health)     HEALTH=true ;;
  esac
done

# ── BOUNCER_DATA_DIR 감지 ─────────────────────────────────────────────────────
# 로컬(.claude/ai-bouncer) 우선 → 글로벌(~/.claude/ai-bouncer) fallback
BOUNCER_DATA_DIR=""
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# 1. 로컬 설치 확인
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/ai-bouncer/config.json" ]; then
  BOUNCER_DATA_DIR=$(
    $PYTHON -c "
import json, sys, os
cfg = json.load(open(sys.argv[1]))
td = cfg.get('target_dir', '')
if td:
    print(os.path.join(td, 'ai-bouncer'))
else:
    print('')
" "$REPO_ROOT/.claude/ai-bouncer/config.json" 2>/dev/null
  ) || true
fi

# 2. 글로벌 설치 확인 (하위 호환)
if [ -z "$BOUNCER_DATA_DIR" ] && [ -f "$HOME/.claude/ai-bouncer/config.json" ]; then
  BOUNCER_DATA_DIR=$(
    $PYTHON -c "
import json, sys, os
cfg = json.load(open(sys.argv[1]))
td = cfg.get('target_dir', '')
if td:
    print(os.path.join(td, 'ai-bouncer'))
else:
    print('')
" "$HOME/.claude/ai-bouncer/config.json" 2>/dev/null
  ) || true
fi

if [ -z "$BOUNCER_DATA_DIR" ] || [ ! -d "$BOUNCER_DATA_DIR" ]; then
  # 설치 정보 없으면 조용히 종료
  exit 0
fi

TARGET_DIR=$(dirname "$BOUNCER_DATA_DIR")

# ── 누락 hook 검증 (매 세션) ──────────────────────────────────────────────────
_ensure_hook() {
  local sf="$1" event="$2" cmd="$3" timeout="${4:-5}" is_async="${5:-false}" matcher="${6:-}"
  [ -f "$sf" ] || return 0
  [ -f "$cmd" ] || return 0
  local bn
  bn=$(basename "$cmd")
  grep -q "$bn" "$sf" 2>/dev/null && return 0
  $PYTHON -c "
import json, sys
sf, event, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
timeout, is_async, matcher = int(sys.argv[4]), sys.argv[5] == 'true', sys.argv[6]
cfg = json.load(open(sf))
hooks = cfg.setdefault('hooks', {})
entries = hooks.setdefault(event, [])
hook = {'type': 'command', 'command': cmd, 'timeout': timeout}
if is_async:
    hook['async'] = True
entry = {'hooks': [hook]}
if matcher:
    entry['matcher'] = matcher
entries.append(entry)
with open(sf, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('added')
" "$sf" "$event" "$cmd" "$timeout" "$is_async" "$matcher" >/dev/null 2>&1
  echo "✓  ${event} hook 등록: $bn" >&2
}

HOOKS_JSON="$BOUNCER_DATA_DIR/hooks/hooks.json"
SETTINGS_FILE="$TARGET_DIR/settings.json"
if [ -f "$HOOKS_JSON" ] && [ -f "$SETTINGS_FILE" ]; then
  while IFS=$'\t' read -r _ev _matcher _file; do
    _cmd="$BOUNCER_DATA_DIR/hooks/$_file"
    _ensure_hook "$SETTINGS_FILE" "$_ev" "$_cmd" 5 false "$_matcher" || true
  done < <($PYTHON -c "
import json, sys
hj = json.load(open(sys.argv[1]))
for event, entries in hj.items():
    for e in entries:
        matcher = e.get('matcher', '')
        print(f\"{event}\t{matcher}\t{e['file']}\")
" "$HOOKS_JSON")
  # SessionStart: 자기 자신
  _ensure_hook "$SETTINGS_FILE" "SessionStart" "$BOUNCER_DATA_DIR/scripts/bouncer-update-check.sh" 30 false "" || true
fi

MANIFEST="$BOUNCER_DATA_DIR/manifest.json"
CHECKED_FILE="$BOUNCER_DATA_DIR/.version-checked"
TARGET_DIR=$(dirname "$BOUNCER_DATA_DIR")

# ── 헬스체크 ─────────────────────────────────────────────────────────────────
_run_health_check() {
  local issues=0

  # 1. hooks.json에 등재된 hook 파일 존재 확인
  local hooks_json="$BOUNCER_DATA_DIR/hooks/hooks.json"
  if [ -f "$hooks_json" ]; then
    local missing
    missing=$($PYTHON -c "
import json, sys, os
hj = json.load(open(sys.argv[1]))
bd = sys.argv[2]
missing = []
for entries in hj.values():
    for e in entries:
        f = os.path.join(bd, 'hooks', e['file'])
        if not os.path.isfile(f):
            missing.append(e['file'])
if missing:
    print(', '.join(missing))
" "$hooks_json" "$BOUNCER_DATA_DIR" 2>/dev/null) || true
    if [ -n "$missing" ]; then
      echo "⚠ ai-bouncer: 누락된 hook 파일: $missing"
      issues=$((issues + 1))
    fi
  else
    echo "⚠ ai-bouncer: hooks.json 없음"
    issues=$((issues + 1))
  fi

  # 2. settings.json에 핵심 hook 등록 확인
  local settings="$TARGET_DIR/settings.json"
  if [ -f "$settings" ]; then
    local unreg
    unreg=$($PYTHON -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
hooks = cfg.get('hooks', {})
needed = ['plan-gate.sh', 'bash-gate.sh', 'completion-gate.sh']
all_cmds = [h.get('command','') for gs in hooks.values() for g in gs for h in g.get('hooks',[])]
missing = [n for n in needed if not any(n in c for c in all_cmds)]
if missing:
    print(', '.join(missing))
" "$settings" 2>/dev/null) || true
    if [ -n "$unreg" ]; then
      echo "⚠ ai-bouncer: settings.json에 미등록 hook: $unreg"
      issues=$((issues + 1))
    fi
  fi

  # 3. CLAUDE.md에 bouncer 규칙 확인
  local claude_md="$TARGET_DIR/CLAUDE.md"
  if [ -f "$claude_md" ]; then
    if ! grep -q "ai-bouncer-rule" "$claude_md" 2>/dev/null; then
      echo "⚠ ai-bouncer: CLAUDE.md에 bouncer 규칙 없음"
      issues=$((issues + 1))
    fi
  fi

  if [ "$issues" -gt 0 ]; then
    echo "⚠ ai-bouncer 설치 손상 감지 (${issues}건). bash update.sh로 복구하세요."
  fi
  return $issues
}

if [ "$HEALTH" = true ]; then
  _run_health_check
  exit $?
fi

# ── 24시간 throttle ───────────────────────────────────────────────────────────
if [ "$FORCE" = false ] && [ "$CHECK_ONLY" = false ] && [ -f "$CHECKED_FILE" ]; then
  LAST=$(cat "$CHECKED_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DIFF=$(( NOW - LAST ))
  if [ "$DIFF" -lt 86400 ]; then
    exit 0
  fi
fi

# ── 최신 SHA 조회 ────────────────────────────────────────────────────────────
LATEST_SHA=$(curl -sf --max-time 5 "$API_URL" 2>/dev/null | $PYTHON -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['sha'][:7])
except:
    sys.exit(1)
" 2>/dev/null) || {
  # 네트워크 실패 시 조용히 종료
  exit 0
}

# 체크 타임스탬프 갱신
date +%s > "$CHECKED_FILE"

# ── 설치된 버전 확인 ─────────────────────────────────────────────────────────
INSTALLED_SHA=$($PYTHON -c "
import json, sys
try:
    m = json.load(open(sys.argv[1]))
    print(m.get('version', 'unknown'))
except:
    print('unknown')
" "$MANIFEST" 2>/dev/null) || echo "unknown"

if [ "$CHECK_ONLY" = true ]; then
  echo "installed: $INSTALLED_SHA"
  echo "latest:    $LATEST_SHA"
  if [ "$LATEST_SHA" = "$INSTALLED_SHA" ]; then
    echo "status: up-to-date"
  else
    echo "status: update-available"
  fi
  exit 0
fi

# ── 업데이트 필요 없으면 종료 ────────────────────────────────────────────────
if [ "$LATEST_SHA" = "$INSTALLED_SHA" ]; then
  exit 0
fi

# ── bootstrap: 자기 자신을 먼저 업데이트 후 재실행 ────────────────────────────
SELF_SCRIPT="$TARGET_DIR/scripts/bouncer-update-check.sh"
if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ]; then
  SELF_TMP=$(mktemp) || { echo "ai-bouncer: mktemp failed" >&2; exit 0; }
  trap 'rm -f "$SELF_TMP"' EXIT
  if curl -sf --max-time 10 "$RAW_BASE/scripts/bouncer-update-check.sh" -o "$SELF_TMP" 2>/dev/null; then
    # 무결성 검증: 비어있지 않고, 유효한 bash 구문이어야 함
    if [ -s "$SELF_TMP" ] && bash -n "$SELF_TMP" 2>/dev/null; then
      if ! cmp -s "$SELF_TMP" "$SELF_SCRIPT"; then
        mv "$SELF_TMP" "$SELF_SCRIPT"
        chmod +x "$SELF_SCRIPT"
        trap - EXIT
        export _UPDATE_BOOTSTRAPPED=1
        exec bash "$SELF_SCRIPT" --force
      fi
    else
      echo "ai-bouncer: 다운로드 파일 검증 실패, 업데이트 건너뜀" >&2
    fi
  fi
  rm -f "$SELF_TMP"
  trap - EXIT
fi

# ── git clone → update.sh 실행 ───────────────────────────────────────────────
_G='\033[0;32m' _D='\033[2m' _R='\033[0;31m' _B='\033[1m' _N='\033[0m'

CLONE_DIR=$(mktemp -d) || { echo "ai-bouncer: mktemp -d failed" >&2; exit 0; }
trap 'rm -rf "$CLONE_DIR"' EXIT

if ! git clone --depth 1 "https://github.com/$REPO.git" "$CLONE_DIR/ai-bouncer" -q 2>/dev/null; then
  echo "ai-bouncer: git clone 실패, 업데이트 건너뜀" >&2
  exit 0
fi

# update.sh 실행
if [ -f "$CLONE_DIR/ai-bouncer/update.sh" ]; then
  (cd "$(dirname "$TARGET_DIR")" && bash "$CLONE_DIR/ai-bouncer/update.sh") || {
    echo "ai-bouncer: update.sh 실행 실패" >&2
    exit 0
  }
else
  echo "ai-bouncer: update.sh를 찾을 수 없음" >&2
  exit 0
fi

# 클론 디렉토리 정리 (trap에서 처리)

echo -e "\n${_G}✓${_N}  ${_B}ai-bouncer${_N} $INSTALLED_SHA → $LATEST_SHA 업데이트 완료"
echo "ai-bouncer $INSTALLED_SHA → $LATEST_SHA 업데이트 완료"
