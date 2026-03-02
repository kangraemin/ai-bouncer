#!/bin/bash
# ai-bouncer install
# Usage: bash install.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "${GREEN}✓${NC}  $*"; }
info()   { echo -e "${BLUE}ℹ${NC}  $*"; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*"; }
header() { echo -e "\n${BOLD}── $* ──${NC}\n"; }

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 설치 범위 ──────────────────────────────────────────────────
header "설치 범위"
echo "  1) 전역 (~/.claude/) — 모든 프로젝트에 적용"
echo "  2) 로컬 (.claude/)  — 현재 프로젝트에만 적용"
echo ""
printf "선택 [1]: "
read -r SCOPE_CHOICE
SCOPE_CHOICE="${SCOPE_CHOICE:-1}"

if [ "$SCOPE_CHOICE" = "2" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -z "$REPO_ROOT" ]; then
    echo "에러: git 레포 안에서 실행해주세요."
    exit 1
  fi
  TARGET_DIR="$REPO_ROOT/.claude"
  SCOPE="local"
else
  TARGET_DIR="$HOME/.claude"
  SCOPE="global"
fi

info "설치 대상: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# ── 파일 복사 ──────────────────────────────────────────────────
header "파일 설치"

# 관리 블록만 교체하는 함수 (ai-worklog 방식)
install_file() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    ok "$(basename "$dst") (새로 설치)"
    return
  fi

  python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
import sys

src_path     = sys.argv[1]
dst_path     = sys.argv[2]
start_marker = sys.argv[3]
end_marker   = sys.argv[4]

src = open(src_path, encoding='utf-8').read()
dst = open(dst_path, encoding='utf-8').read()

s_start = src.find(start_marker)
s_end   = src.find(end_marker)

if s_start == -1 or s_end == -1:
    open(dst_path, 'w', encoding='utf-8').write(src)
    sys.exit(0)

managed_block = src[s_start : s_end + len(end_marker)]

d_start = dst.find(start_marker)
d_end   = dst.find(end_marker)

if d_start != -1 and d_end != -1:
    new_dst = dst[:d_start] + managed_block + dst[d_end + len(end_marker):]
else:
    import re
    exit_match = re.search(r'^exit\s+0\s*$', dst, re.MULTILINE)
    if exit_match:
        pos = exit_match.start()
        new_dst = dst[:pos] + managed_block + '\n\n' + dst[pos:]
    else:
        new_dst = dst.rstrip('\n') + '\n\n' + managed_block + '\n'

open(dst_path, 'w', encoding='utf-8').write(new_dst)
PYEOF

  ok "$(basename "$dst") (관리 블록 업데이트)"
}

# 덮어쓰기 복사
copy_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  ok "$(basename "$dst")"
}

# agents
copy_file "$PACKAGE_DIR/agents/lead.md"    "$TARGET_DIR/agents/lead.md"
copy_file "$PACKAGE_DIR/agents/dev.md"     "$TARGET_DIR/agents/dev.md"
copy_file "$PACKAGE_DIR/agents/qa.md"      "$TARGET_DIR/agents/qa.md"

# commands
copy_file "$PACKAGE_DIR/commands/dev.md"   "$TARGET_DIR/commands/dev.md"

# hooks
install_file "$PACKAGE_DIR/hooks/plan-gate.sh" "$TARGET_DIR/hooks/plan-gate.sh"
chmod +x "$TARGET_DIR/hooks/plan-gate.sh"

# ── state.json 초기화 ──────────────────────────────────────────
STATE_DIR="$HOME/.claude/ai-bouncer"
STATE_FILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR"

if [ ! -f "$STATE_FILE" ]; then
  cat > "$STATE_FILE" <<'JSON'
{
  "plan_approved": false,
  "current_step": 0,
  "steps": {}
}
JSON
  ok "state.json 초기화"
fi

# ── settings.json에 PreToolUse hook 등록 ──────────────────────
header "settings.json 설정"

SETTINGS_FILE="$TARGET_DIR/settings.json"
HOOK_CMD="$TARGET_DIR/hooks/plan-gate.sh"

python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PYEOF'
import json, sys, os

settings_file = sys.argv[1]
hook_cmd      = sys.argv[2]

cfg = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding='utf-8') as f:
        cfg = json.load(f)

hooks = cfg.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])

# 이미 등록됐는지 확인
for group in pre:
    for h in group.get('hooks', []):
        if hook_cmd in h.get('command', ''):
            print(f'  · PreToolUse hook 이미 등록됨')
            sys.exit(0)

pre.append({
    'matcher': 'Write|Edit|MultiEdit',
    'hooks': [{'type': 'command', 'command': hook_cmd}]
})

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f'  ✓ PreToolUse hook 등록 완료')
PYEOF

# ── 버전 기록 ──────────────────────────────────────────────────
INSTALLED_SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$INSTALLED_SHA" > "$TARGET_DIR/.ai-bouncer-version"
ok "버전 기록: $INSTALLED_SHA"

# ── 완료 ──────────────────────────────────────────────────────
header "설치 완료"
echo -e "  ${BOLD}설정 요약${NC}"
echo "  ├─ 범위: $SCOPE ($TARGET_DIR)"
echo "  ├─ agents: lead.md, dev.md, qa.md"
echo "  ├─ commands: dev.md"
echo "  ├─ hooks: plan-gate.sh (PreToolUse)"
echo "  └─ state: $HOME/.claude/ai-bouncer/state.json"
echo ""
ok "ai-bouncer 설치 완료!"
