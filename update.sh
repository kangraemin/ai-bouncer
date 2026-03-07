#!/bin/bash
# ai-bouncer 빠른 업데이트
# 기존 설치된 파일을 소스에서 덮어쓰기 (설정 변경 없음)
# Usage: bash update.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()  { echo -e "${GREEN}✓${NC}  $*"; }
err() { echo -e "${RED}✗${NC}  $*"; }

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.claude/ai-bouncer/config.json"

if [ -f "$CONFIG_FILE" ]; then
  TARGET_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('target_dir','$HOME/.claude'))")
elif [ -d "$HOME/.claude/hooks" ]; then
  TARGET_DIR="$HOME/.claude"
else
  err "ai-bouncer가 설치되어 있지 않습니다. install.sh를 먼저 실행하세요."
  exit 1
fi

echo -e "${BOLD}ai-bouncer 업데이트${NC} → $TARGET_DIR"
echo ""

# agents
for agent in intent planner-lead planner-dev planner-qa verifier lead dev qa; do
  src="$PACKAGE_DIR/agents/${agent}.md"
  dst="$TARGET_DIR/agents/${agent}.md"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    ok "$agent (agent)"
  fi
done

# skills
SKILL_DST="$HOME/.claude/skills/dev-bounce"
mkdir -p "$SKILL_DST"
cp -r "$PACKAGE_DIR/skills/dev-bounce/." "$SKILL_DST/"
ok "dev-bounce (skill)"

# hooks (managed block 교체)
install_hook() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod +x "$dst"
    ok "$(basename "$dst") (새로 설치)"
    return
  fi

  python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
import sys, re

src_path, dst_path = sys.argv[1], sys.argv[2]
start_marker, end_marker = sys.argv[3], sys.argv[4]

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
    exit_match = re.search(r'^exit\s+0\s*$', dst, re.MULTILINE)
    if exit_match:
        pos = exit_match.start()
        new_dst = dst[:pos] + managed_block + '\n\n' + dst[pos:]
    else:
        new_dst = dst.rstrip('\n') + '\n\n' + managed_block + '\n'

open(dst_path, 'w', encoding='utf-8').write(new_dst)
PYEOF
  chmod +x "$dst"
  ok "$(basename "$dst") (hook)"
}

install_hook "$PACKAGE_DIR/hooks/plan-gate.sh"       "$TARGET_DIR/hooks/plan-gate.sh"
install_hook "$PACKAGE_DIR/hooks/bash-gate.sh"       "$TARGET_DIR/hooks/bash-gate.sh"
install_hook "$PACKAGE_DIR/hooks/bash-audit.sh"      "$TARGET_DIR/hooks/bash-audit.sh"
install_hook "$PACKAGE_DIR/hooks/doc-reminder.sh"    "$TARGET_DIR/hooks/doc-reminder.sh"
install_hook "$PACKAGE_DIR/hooks/completion-gate.sh"  "$TARGET_DIR/hooks/completion-gate.sh"

# lib
mkdir -p "$TARGET_DIR/hooks/lib"
cp "$PACKAGE_DIR/hooks/lib/resolve-task.sh" "$TARGET_DIR/hooks/lib/resolve-task.sh"
chmod +x "$TARGET_DIR/hooks/lib/resolve-task.sh"
ok "resolve-task.sh (lib)"

# 매니페스트 업데이트
MANIFEST="$HOME/.claude/ai-bouncer/manifest.json"
mkdir -p "$HOME/.claude/ai-bouncer"
SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
python3 -c "
import json, datetime, os
m = json.load(open('$MANIFEST')) if os.path.exists('$MANIFEST') else {}
m['version'] = '$SHA'
m['updated_at'] = datetime.datetime.now().isoformat()
json.dump(m, open('$MANIFEST','w'), indent=2)
"
ok "매니페스트 ($SHA)"

echo ""
echo -e "${GREEN}✓${NC}  ${BOLD}업데이트 완료${NC}"
