#!/bin/bash
# ai-bouncer 자동 업데이트 체커
# Usage: update-check.sh [--force] [--check-only]
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
for arg in "$@"; do
  case $arg in
    --force)      FORCE=true ;;
    --check-only) CHECK_ONLY=true ;;
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

MANIFEST="$BOUNCER_DATA_DIR/manifest.json"
CHECKED_FILE="$BOUNCER_DATA_DIR/.version-checked"
TARGET_DIR=$(dirname "$BOUNCER_DATA_DIR")

# ── 24시간 throttle ───────────────────────────────────────────────────────────
if [ "$FORCE" = false ] && [ -f "$CHECKED_FILE" ]; then
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
SELF_SCRIPT="$TARGET_DIR/scripts/update-check.sh"
if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ]; then
  SELF_TMP=$(mktemp) || { echo "ai-bouncer: mktemp failed" >&2; exit 0; }
  trap 'rm -f "$SELF_TMP"' EXIT
  if curl -sf --max-time 10 "$RAW_BASE/scripts/update-check.sh" -o "$SELF_TMP" 2>/dev/null; then
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
