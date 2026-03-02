#!/bin/bash
# ai-bouncer install/update/uninstall
# Usage:
#   bash install.sh            — 신규 설치 또는 업데이트
#   bash install.sh --update   — 최신 파일로 업데이트
#   bash install.sh --uninstall — 제거

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

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-install}"

# ── 언인스톨 ──────────────────────────────────────────────────
if [ "$MODE" = "--uninstall" ]; then
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

  # 매니페스트 삭제
  rm -f "$HOME/.claude/ai-bouncer/manifest.json"
  rm -f "$HOME/.claude/ai-bouncer/config.json"
  rmdir "$HOME/.claude/ai-bouncer" 2>/dev/null || true

  echo ""
  ok "ai-bouncer 제거 완료"
  exit 0
fi

# ── --config 모드 ──────────────────────────────────────────────
if [ "$MODE" = "--config" ]; then
  header "커밋 전략 재설정"
  CONFIG_FILE="$HOME/.claude/ai-bouncer/config.json"
  if [ ! -f "$CONFIG_FILE" ]; then
    err "ai-bouncer가 설치되어 있지 않습니다. 먼저 install.sh를 실행하세요."
    exit 1
  fi
  echo "  커밋 전략:"
  echo "  1) per-step  — Step 완료마다 즉시 커밋 + 푸시 (기본값)"
  echo "  2) per-phase — 개발 Phase 전체 완료 시 커밋 + 푸시"
  echo "  3) none      — 커밋하지 않음 (수동 관리)"
  echo ""
  printf "  선택 [1]: "
  read -r COMMIT_CHOICE
  COMMIT_CHOICE="${COMMIT_CHOICE:-1}"
  case "$COMMIT_CHOICE" in
    2) COMMIT_STRATEGY="per-phase" ;;
    3) COMMIT_STRATEGY="none" ;;
    *) COMMIT_STRATEGY="per-step" ;;
  esac

  # 커밋 스킬 재감지
  if [ -f "$HOME/.claude/commands/commit.md" ] || [ -f ".claude/commands/commit.md" ]; then
    COMMIT_SKILL_BOOL="true"
  else
    COMMIT_SKILL_BOOL="false"
  fi

  python3 - "$CONFIG_FILE" "$COMMIT_STRATEGY" "$COMMIT_SKILL_BOOL" <<'PYEOF'
import json, sys
cfg_file, strategy, skill = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
with open(cfg_file) as f: cfg = json.load(f)
cfg["commit_strategy"] = strategy
cfg["commit_skill"] = skill
with open(cfg_file, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  commit_strategy = {strategy}")
print(f"  commit_skill    = {skill}")
PYEOF
  ok "커밋 전략 업데이트 완료"
  exit 0
fi

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
    err "에러: git 레포 안에서 실행해주세요."
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

# 기존 설치 감지
MANIFEST="$HOME/.claude/ai-bouncer/manifest.json"
IS_UPDATE=false
if [ -f "$MANIFEST" ]; then
  IS_UPDATE=true
  info "기존 설치 감지 → 업데이트 모드"
fi

# ── 파일 복사 함수 ──────────────────────────────────────────────
INSTALLED_FILES=()
DATE_TAG=$(date +%Y%m%d)

# 백업 후 덮어쓰기
copy_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"

  if [ -f "$dst" ]; then
    # 기존 파일이 ai-bouncer 파일인지 확인 (매니페스트 기반)
    cp "$dst" "${dst}.backup-${DATE_TAG}" 2>/dev/null || true
  fi

  cp "$src" "$dst"
  INSTALLED_FILES+=("$(realpath --relative-to="$TARGET_DIR" "$dst" 2>/dev/null || echo "$dst")")
  ok "$(basename "$dst")"
}

# 관리 블록 교체 (hooks용)
install_hook() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    ok "$(basename "$dst") (새로 설치)"
  else
    cp "$dst" "${dst}.backup-${DATE_TAG}" 2>/dev/null || true
    python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
import sys, re

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
    exit_match = re.search(r'^exit\s+0\s*$', dst, re.MULTILINE)
    if exit_match:
        pos = exit_match.start()
        new_dst = dst[:pos] + managed_block + '\n\n' + dst[pos:]
    else:
        new_dst = dst.rstrip('\n') + '\n\n' + managed_block + '\n'

open(dst_path, 'w', encoding='utf-8').write(new_dst)
PYEOF
    ok "$(basename "$dst") (업데이트)"
  fi

  chmod +x "$dst"
  INSTALLED_FILES+=("$(realpath --relative-to="$TARGET_DIR" "$dst" 2>/dev/null || echo "$dst")")
}

# ── 파일 설치 ──────────────────────────────────────────────────
header "파일 설치"

# agents — 신규 에이전트 포함
copy_file "$PACKAGE_DIR/agents/intent.md"        "$TARGET_DIR/agents/intent.md"
copy_file "$PACKAGE_DIR/agents/planner-lead.md"  "$TARGET_DIR/agents/planner-lead.md"
copy_file "$PACKAGE_DIR/agents/planner-dev.md"   "$TARGET_DIR/agents/planner-dev.md"
copy_file "$PACKAGE_DIR/agents/planner-qa.md"    "$TARGET_DIR/agents/planner-qa.md"
copy_file "$PACKAGE_DIR/agents/verifier.md"      "$TARGET_DIR/agents/verifier.md"
copy_file "$PACKAGE_DIR/agents/lead.md"          "$TARGET_DIR/agents/lead.md"
copy_file "$PACKAGE_DIR/agents/dev.md"           "$TARGET_DIR/agents/dev.md"
copy_file "$PACKAGE_DIR/agents/qa.md"            "$TARGET_DIR/agents/qa.md"

# commands
copy_file "$PACKAGE_DIR/commands/dev-bounce.md"  "$TARGET_DIR/commands/dev-bounce.md"

# hooks
install_hook "$PACKAGE_DIR/hooks/plan-gate.sh"     "$TARGET_DIR/hooks/plan-gate.sh"
install_hook "$PACKAGE_DIR/hooks/doc-reminder.sh"  "$TARGET_DIR/hooks/doc-reminder.sh"
install_hook "$PACKAGE_DIR/hooks/completion-gate.sh" "$TARGET_DIR/hooks/completion-gate.sh"

# ── docs git 추적 설정 ─────────────────────────────────────────
header "docs/ 설정"
echo "  ai-bouncer는 작업별로 docs/<task-name>/ 폴더에 산출물을 저장합니다."
echo ""
printf "  docs/ 폴더를 git으로 추적할까요? (y/n) [n]: "
read -r DOCS_GIT_TRACK
DOCS_GIT_TRACK="${DOCS_GIT_TRACK:-n}"

DOCS_TRACK_BOOL="false"
if [[ "$DOCS_GIT_TRACK" =~ ^[yY] ]]; then
  DOCS_TRACK_BOOL="true"
  ok "docs/ git 추적 활성화"
else
  ok "docs/ git 미추적 (기본값)"
fi

# 커밋 전략 선택
header "커밋 전략"
echo "  Step/Phase 완료 시 자동 커밋 전략을 선택하세요."
echo ""
echo "  1) per-step  — Step 완료마다 즉시 커밋 + 푸시 (기본값)"
echo "  2) per-phase — 개발 Phase 전체 완료 시 커밋 + 푸시"
echo "  3) none      — 커밋하지 않음 (수동 관리)"
echo ""
printf "  선택 [1]: "
read -r COMMIT_CHOICE
COMMIT_CHOICE="${COMMIT_CHOICE:-1}"
case "$COMMIT_CHOICE" in
  2) COMMIT_STRATEGY="per-phase" ;;
  3) COMMIT_STRATEGY="none" ;;
  *) COMMIT_STRATEGY="per-step" ;;
esac

# 커밋 스킬 감지
if [ -f "$HOME/.claude/commands/commit.md" ] || [ -f ".claude/commands/commit.md" ]; then
  COMMIT_SKILL_BOOL="true"
  ok "커밋 스킬 감지됨 (commit.md) — 커밋 시 /commit 스킬 활용"
else
  COMMIT_SKILL_BOOL="false"
  ok "커밋 스킬 없음 — 일반 git commit 사용"
fi
ok "커밋 전략: $COMMIT_STRATEGY"

# config.json 저장
mkdir -p "$HOME/.claude/ai-bouncer"
cat > "$HOME/.claude/ai-bouncer/config.json" << JSON
{
  "docs_git_track": $DOCS_TRACK_BOOL,
  "commit_strategy": "$COMMIT_STRATEGY",
  "commit_skill": $COMMIT_SKILL_BOOL,
  "target_dir": "$TARGET_DIR"
}
JSON
ok "config.json 저장됨"

# ── CLAUDE.md 규칙 주입 ─────────────────────────────────────────
header "CLAUDE.md 규칙 주입"

CLAUDE_FILE="$TARGET_DIR/CLAUDE.md"

python3 - "$CLAUDE_FILE" <<'PYEOF'
import sys, re, os

claude_file = sys.argv[1]

START = "# --- ai-bouncer-rule start ---"
END   = "# --- ai-bouncer-rule end ---"

block = """\
# --- ai-bouncer-rule start ---
## ai-bouncer
코드 수정 / 기능 구현 / 파일 변경 / 버그 수정 등 개발 작업 시 반드시 `/dev-bounce` 스킬을 먼저 호출할 것.
# --- ai-bouncer-rule end ---"""

if os.path.exists(claude_file):
    content = open(claude_file, encoding='utf-8').read()
    s = content.find(START)
    e = content.find(END)
    if s != -1 and e != -1:
        # 기존 블록 교체
        new_content = content[:s] + block + content[e + len(END):]
        print("  기존 블록 교체됨")
    else:
        # 파일 끝에 추가
        new_content = content.rstrip('\n') + '\n\n' + block + '\n'
        print("  기존 파일에 블록 추가됨")
else:
    # 신규 생성
    new_content = block + '\n'
    print("  CLAUDE.md 신규 생성 후 블록 주입됨")

os.makedirs(os.path.dirname(claude_file) if os.path.dirname(claude_file) else '.', exist_ok=True)
open(claude_file, 'w', encoding='utf-8').write(new_content)
PYEOF

# ── settings.json에 hooks 등록 ─────────────────────────────────
header "settings.json 설정"

SETTINGS_FILE="$TARGET_DIR/settings.json"

python3 - "$SETTINGS_FILE" "$TARGET_DIR" <<'PYEOF'
import json, sys, os

settings_file = sys.argv[1]
target_dir = sys.argv[2]

cfg = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding='utf-8') as f:
        cfg = json.load(f)

hooks = cfg.setdefault('hooks', {})

def is_registered(hook_list, cmd_fragment):
    for group in hook_list:
        for h in group.get('hooks', []):
            if cmd_fragment in h.get('command', ''):
                return True
    return False

def add_hook(hook_type, matcher, cmd):
    hook_list = hooks.setdefault(hook_type, [])
    cmd_path = os.path.join(target_dir, 'hooks', cmd)
    if not is_registered(hook_list, cmd):
        entry = {'hooks': [{'type': 'command', 'command': cmd_path}]}
        if matcher:
            entry['matcher'] = matcher
        hook_list.append(entry)
        print(f"  ✓ {hook_type} hook 등록: {cmd}")
    else:
        print(f"  · {hook_type} hook 이미 등록됨: {cmd}")

add_hook('PreToolUse', 'Write|Edit|MultiEdit', 'plan-gate.sh')
add_hook('PostToolUse', 'Write|Edit|MultiEdit', 'doc-reminder.sh')
add_hook('Stop', None, 'completion-gate.sh')

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF

# ── 매니페스트 업데이트 ────────────────────────────────────────
header "매니페스트 기록"

mkdir -p "$HOME/.claude/ai-bouncer"
INSTALLED_SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

python3 - "$MANIFEST" "$INSTALLED_SHA" "${INSTALLED_FILES[@]}" <<'PYEOF'
import json, sys, os

manifest_path = sys.argv[1]
version = sys.argv[2]
files = sys.argv[3:] if len(sys.argv) > 3 else []

manifest = {
    "version": version,
    "installed_at": __import__('datetime').datetime.now().isoformat(),
    "files": files
}

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)

print(f"  버전: {version}")
print(f"  파일 수: {len(files)}")
PYEOF

ok "매니페스트 저장됨"

# ── 완료 ──────────────────────────────────────────────────────
header "설치 완료"
echo -e "  ${BOLD}설정 요약${NC}"
echo "  ├─ 범위: $SCOPE ($TARGET_DIR)"
echo "  ├─ agents: intent, planner-lead, planner-dev, planner-qa, verifier, lead, dev, qa"
echo "  ├─ commands: dev-bounce.md (/dev-bounce)"
echo "  ├─ hooks: plan-gate.sh (PreToolUse)"
echo "  │         doc-reminder.sh (PostToolUse)"
echo "  │         completion-gate.sh (Stop)"
echo "  ├─ docs git 추적: $DOCS_TRACK_BOOL"
echo "  └─ 매니페스트: $MANIFEST"
echo ""
echo -e "  사용법: 프로젝트에서 ${BOLD}/dev <요청>${NC} 실행"
echo ""
ok "ai-bouncer 설치 완료!"
