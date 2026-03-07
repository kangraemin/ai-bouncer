#!/bin/bash
# ai-bouncer uninstall
# Usage: bash uninstall.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()     { echo -e "${GREEN}✓${NC}  $*"; }
info()   { echo -e "${BLUE}ℹ${NC}  $*"; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*"; }
err()    { echo -e "${RED}✗${NC}  $*"; }
header() { echo -e "\n${BOLD}── $* ──${NC}\n"; }

header "ai-bouncer 제거"

# 설치 범위 감지
TARGET_DIR=""
if [ -f "$HOME/.claude/ai-bouncer/manifest.json" ]; then
  TARGET_DIR="$HOME/.claude"
fi

if [ -z "$TARGET_DIR" ]; then
  err "설치된 ai-bouncer를 찾을 수 없습니다."
  exit 1
fi

MANIFEST="$HOME/.claude/ai-bouncer/manifest.json"
info "매니페스트에서 설치 파일 목록 읽는 중..."

python3 - "$MANIFEST" "$TARGET_DIR" <<'PYEOF'
import json, os, sys

manifest_path = sys.argv[1]
target_dir = sys.argv[2]

with open(manifest_path) as f:
    manifest = json.load(f)

removed = 0
for rel_path in manifest.get('files', []):
    abs_path = os.path.join(target_dir, rel_path)
    if os.path.exists(abs_path):
        os.remove(abs_path)
        print(f"  삭제: {rel_path}")
        removed += 1

print(f"\n  {removed}개 파일 삭제됨 (백업 파일은 유지)")
PYEOF

# settings.json에서 hook 제거
SETTINGS_FILE="$TARGET_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  python3 - "$SETTINGS_FILE" "$TARGET_DIR" <<'PYEOF'
import json, os, sys

settings_file = sys.argv[1]
target_dir = sys.argv[2]

with open(settings_file) as f:
    cfg = json.load(f)

hooks = cfg.get('hooks', {})
for hook_type in ['PreToolUse', 'PostToolUse', 'Stop']:
    if hook_type in hooks:
        original = hooks[hook_type]
        filtered = [
            g for g in original
            if not any('ai-bouncer' in h.get('command', '') for h in g.get('hooks', []))
        ]
        if len(filtered) != len(original):
            hooks[hook_type] = filtered
            print(f"  {hook_type} hook 제거됨")

if not any(hooks.values()):
    cfg.pop('hooks', None)

with open(settings_file, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
fi

# CLAUDE.md 블록 제거
CONFIG_JSON="$HOME/.claude/ai-bouncer/config.json"
if [ -f "$CONFIG_JSON" ]; then
  UNINSTALL_TARGET_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON')).get('target_dir',''))" 2>/dev/null || echo "")
  if [ -n "$UNINSTALL_TARGET_DIR" ]; then
    CLAUDE_FILE="$UNINSTALL_TARGET_DIR/CLAUDE.md"
    if [ -f "$CLAUDE_FILE" ]; then
      python3 - "$CLAUDE_FILE" <<'PYEOF'
import sys, re

claude_file = sys.argv[1]
START = "# --- ai-bouncer-rule start ---"
END   = "# --- ai-bouncer-rule end ---"

content = open(claude_file, encoding='utf-8').read()
s = content.find(START)
e = content.find(END)

if s == -1 or e == -1:
    print("  CLAUDE.md 블록 없음 (no-op)")
    sys.exit(0)

# 마커 포함 블록 제거, 앞뒤 빈줄 정리
before = content[:s].rstrip('\n')
after  = content[e + len(END):].lstrip('\n')
new_content = (before + '\n' + after).strip('\n')
if new_content:
    new_content += '\n'

open(claude_file, 'w', encoding='utf-8').write(new_content)
print("  CLAUDE.md ai-bouncer 규칙 블록 제거됨")
PYEOF
    fi
  fi
fi

# 매니페스트 삭제
rm -f "$HOME/.claude/ai-bouncer/manifest.json"
rm -f "$HOME/.claude/ai-bouncer/config.json"
rmdir "$HOME/.claude/ai-bouncer" 2>/dev/null || true

echo ""
ok "ai-bouncer 제거 완료"
