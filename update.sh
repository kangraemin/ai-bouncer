#!/bin/bash
# ai-bouncer 빠른 업데이트
# 기존 설치된 파일을 소스에서 덮어쓰기 (설정 변경 없음)
# Usage: bash update.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

DIM='\033[2m'

ok()   { echo -e "${GREEN}✓${NC}  $*"; }
skip() { echo -e "${DIM}·  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*"; }

UPDATED=0
UNCHANGED=0

copy_if_changed() {
  local src="$1" dst="$2" label="$3"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    skip "$label"
    UNCHANGED=$((UNCHANGED + 1))
  else
    cp "$src" "$dst"
    ok "$label"
    UPDATED=$((UPDATED + 1))
  fi
}

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PACKAGE_DIR 유효성 검사 (원격 실행 / 설치된 update.sh 대응)
if [ ! -f "$PACKAGE_DIR/agents/intent.md" ]; then
  echo -e "${BOLD}최신 소스 다운로드 중...${NC}"
  TMPDIR_UPDATE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_UPDATE"' EXIT
  git clone --depth 1 "${AI_BOUNCER_REPO:-https://github.com/kangraemin/ai-bouncer.git}" "$TMPDIR_UPDATE/ai-bouncer" -q
  PACKAGE_DIR="$TMPDIR_UPDATE/ai-bouncer"
  echo -e "${GREEN}✓${NC}  다운로드 완료"

  # bootstrap: clone된 최신 update.sh로 재실행 (구 버전 코드 실행 방지)
  if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ] && [ -f "$PACKAGE_DIR/update.sh" ]; then
    export _UPDATE_BOOTSTRAPPED=1
    exec bash "$PACKAGE_DIR/update.sh" "$@"
  fi
fi

# 설치 경로 감지: 로컬(.claude/) 우선, 글로벌(~/.claude/) fallback
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

TARGET_DIR=""

# 1. 로컬 설치 확인
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/ai-bouncer/config.json" ]; then
  CONFIG_FILE="$REPO_ROOT/.claude/ai-bouncer/config.json"
  TARGET_DIR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('target_dir',sys.argv[2]))" "$CONFIG_FILE" "$REPO_ROOT/.claude")
fi

# 2. 글로벌 설치 확인 (하위 호환)
if [ -z "$TARGET_DIR" ] && [ -f "$HOME/.claude/ai-bouncer/config.json" ]; then
  CONFIG_FILE="$HOME/.claude/ai-bouncer/config.json"
  TARGET_DIR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('target_dir',sys.argv[2]))" "$CONFIG_FILE" "$HOME/.claude")
fi

if [ -z "$TARGET_DIR" ]; then
  err "ai-bouncer가 설치되어 있지 않습니다. install.sh를 먼저 실행하세요."
  exit 1
fi

BOUNCER_DATA_DIR="$TARGET_DIR/ai-bouncer"

echo -e "${BOLD}ai-bouncer 업데이트${NC} → $TARGET_DIR"
echo ""

# agents (동적 복사 — agents/*.md)
for agent in "$PACKAGE_DIR/agents/"*.md; do
  [ -f "$agent" ] || continue
  dst="$TARGET_DIR/agents/$(basename "$agent")"
  copy_if_changed "$agent" "$dst" "$(basename "$agent") (agent)"
done

# agents 서브디렉토리 (guides/ 등) 동적 복사
for subdir in "$PACKAGE_DIR/agents"/*/; do
  [ -d "$subdir" ] || continue
  dir_name=$(basename "$subdir")
  mkdir -p "$TARGET_DIR/agents/$dir_name"
  for f in "$subdir"*.md; do
    [ -f "$f" ] || continue
    copy_if_changed "$f" "$TARGET_DIR/agents/$dir_name/$(basename "$f")" "$(basename "$f") (agents/$dir_name)"
  done
done

# 소스에 없는 설치된 agent 파일 삭제 (manifest에 기록된 파일만 대상)
MANIFEST="$BOUNCER_DATA_DIR/manifest.json"
for installed in "$TARGET_DIR/agents/"*.md; do
  [ -f "$installed" ] || continue
  rel_path="agents/$(basename "$installed")"
  # manifest에 없으면 사용자가 직접 추가한 파일 → 스킵
  if [ -f "$MANIFEST" ] && ! python3 -c "import json,sys; files=json.load(open(sys.argv[1])).get('files',[]); sys.exit(0 if sys.argv[2] in files else 1)" "$MANIFEST" "$rel_path" 2>/dev/null; then
    continue
  fi
  if [ ! -f "$PACKAGE_DIR/agents/$(basename "$installed")" ]; then
    rm -f "$installed"
    warn "$(basename "$installed") 삭제 (소스에서 제거됨)"
  fi
done

# skills (동적 — skills/*/ 전체)
for skill_dir in "$PACKAGE_DIR/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  SKILL_DST="$TARGET_DIR/skills/$skill_name"
  mkdir -p "$SKILL_DST"
  for sf in "$skill_dir"*; do
    [ -f "$sf" ] || continue
    copy_if_changed "$sf" "$SKILL_DST/$(basename "$sf")" "$(basename "$sf") (skill/$skill_name)"
  done
done

# hooks (managed block 교체)
install_hook() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod +x "$dst"
    ok "$(basename "$dst") (hook — 새로 설치)"
    UPDATED=$((UPDATED + 1))
    return
  fi

  local changed
  changed=$(python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
import sys, re

src_path, dst_path = sys.argv[1], sys.argv[2]
start_marker, end_marker = sys.argv[3], sys.argv[4]

src = open(src_path, encoding='utf-8').read()
dst = open(dst_path, encoding='utf-8').read()

s_start = src.find(start_marker)
s_end   = src.find(end_marker)

if s_start == -1 or s_end == -1:
    if src != dst:
        open(dst_path, 'w', encoding='utf-8').write(src)
        print("changed")
    else:
        print("unchanged")
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

if new_dst == dst:
    print("unchanged")
else:
    open(dst_path, 'w', encoding='utf-8').write(new_dst)
    print("changed")
PYEOF
)
  chmod +x "$dst"
  if [ "$changed" = "changed" ]; then
    ok "$(basename "$dst") (hook)"
    UPDATED=$((UPDATED + 1))
  else
    skip "$(basename "$dst") (hook)"
    UNCHANGED=$((UNCHANGED + 1))
  fi
}

# enforcement_mode 확인 — prompt-only면 hook 복사 스킵
ENFORCEMENT_MODE=$(jq -r '.enforcement_mode // "hooks"' "$CONFIG_FILE" 2>/dev/null || echo "hooks")

# hooks.json 매니페스트 기반 동적 설치
HOOKS_MANIFEST="$PACKAGE_DIR/hooks/hooks.json"
if [ -f "$HOOKS_MANIFEST" ] && [ "$ENFORCEMENT_MODE" = "hooks" ]; then
  # hooks.json 자체도 복사
  mkdir -p "$TARGET_DIR/hooks"
  copy_if_changed "$HOOKS_MANIFEST" "$TARGET_DIR/hooks/hooks.json" "hooks.json (manifest)"

  while read -r htype hfile; do
    src="$PACKAGE_DIR/hooks/$hfile"
    dst="$TARGET_DIR/hooks/$hfile"
    [ -f "$src" ] || continue
    if [ "$htype" = "managed" ]; then
      install_hook "$src" "$dst"
    else
      copy_if_changed "$src" "$dst" "$hfile (hook)"
      chmod +x "$dst"
    fi
  done < <(python3 -c "
import json, sys
manifest = json.load(open(sys.argv[1]))
for hook_type, hooks in manifest.items():
    for h in hooks:
        print(h['type'], h['file'])
" "$HOOKS_MANIFEST")
else
  ok "hook 복사 스킵 (enforcement_mode=prompt-only)"
fi

# hooks/lib/ 동적 복사
if [ -d "$PACKAGE_DIR/hooks/lib" ]; then
  mkdir -p "$TARGET_DIR/hooks/lib"
  for lib in "$PACKAGE_DIR/hooks/lib/"*.sh; do
    [ -f "$lib" ] || continue
    copy_if_changed "$lib" "$TARGET_DIR/hooks/lib/$(basename "$lib")" "$(basename "$lib") (lib)"
    chmod +x "$TARGET_DIR/hooks/lib/$(basename "$lib")"
  done
fi

# scripts/ 동적 복사
if [ -d "$PACKAGE_DIR/scripts" ]; then
  mkdir -p "$TARGET_DIR/scripts"
  for script in "$PACKAGE_DIR/scripts/"*.sh; do
    [ -f "$script" ] || continue
    copy_if_changed "$script" "$TARGET_DIR/scripts/$(basename "$script")" "$(basename "$script") (script)"
    chmod +x "$TARGET_DIR/scripts/$(basename "$script")"
  done
fi

# Stop hook 호환성 패치
inject_stop_compat() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  [ -f "$dst" ] || return 0

  local changed
  changed=$(python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
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
    print("unchanged")
    sys.exit(0)
managed_block = src[s_start : s_end + len(end_marker)]

d_start = dst.find(start_marker)
d_end   = dst.find(end_marker)
if d_start != -1 and d_end != -1:
    new_dst = dst[:d_start] + managed_block + dst[d_end + len(end_marker):]
else:
    if dst.startswith('#!'):
        newline = dst.index('\n') + 1
        new_dst = dst[:newline] + managed_block + '\n' + dst[newline:]
    else:
        new_dst = managed_block + '\n' + dst

if new_dst == dst:
    print("unchanged")
else:
    open(dst_path, 'w', encoding='utf-8').write(new_dst)
    print("changed")
PYEOF
)
  if [ "$changed" = "changed" ]; then
    ok "$(basename "$dst") (stop compat)"
    UPDATED=$((UPDATED + 1))
  else
    skip "$(basename "$dst") (stop compat)"
    UNCHANGED=$((UNCHANGED + 1))
  fi
}

patch_stop_hooks() {
  local settings_file="$1"
  [ -f "$settings_file" ] || return 0

  local stop_hooks
  stop_hooks=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for g in cfg.get('hooks', {}).get('Stop', []):
    for h in g.get('hooks', []):
        cmd = h.get('command', '')
        if cmd and 'completion-gate' not in cmd:
            print(cmd)
" "$settings_file" 2>/dev/null)

  [ -z "$stop_hooks" ] && return 0

  while IFS= read -r hook_path; do
    [ -f "$hook_path" ] || continue
    case "$(basename "$hook_path")" in
      completion-gate.sh|subagent-track.sh|subagent-cleanup.sh) continue ;;
    esac
    inject_stop_compat "$PACKAGE_DIR/hooks/stop-bouncer-compat.sh" "$hook_path"
  done <<< "$stop_hooks"
}

patch_stop_hooks "$HOME/.claude/settings.json"
patch_stop_hooks "$TARGET_DIR/settings.json"

# update.sh / uninstall.sh → 프로젝트 루트
if [ -n "$REPO_ROOT" ]; then
  # 동일 파일이면 복사 스킵 (로컬 실행 시 자기 자신 복사 방지)
  if [ ! -f "$REPO_ROOT/update.sh" ] || [ "$(realpath "$PACKAGE_DIR/update.sh" 2>/dev/null)" != "$(realpath "$REPO_ROOT/update.sh" 2>/dev/null)" ]; then
    copy_if_changed "$PACKAGE_DIR/update.sh" "$REPO_ROOT/update.sh" "update.sh (프로젝트 루트)"
    chmod +x "$REPO_ROOT/update.sh"
  fi
  if [ ! -f "$REPO_ROOT/uninstall.sh" ] || [ "$(realpath "$PACKAGE_DIR/uninstall.sh" 2>/dev/null)" != "$(realpath "$REPO_ROOT/uninstall.sh" 2>/dev/null)" ]; then
    copy_if_changed "$PACKAGE_DIR/uninstall.sh" "$REPO_ROOT/uninstall.sh" "uninstall.sh (프로젝트 루트)"
    chmod +x "$REPO_ROOT/uninstall.sh"
  fi
fi

# post-update: SessionStart hook 등록
_register_session_start() {
  local sf="$1"
  [ -f "$sf" ] || return 0
  local cmd="$TARGET_DIR/scripts/update-check.sh"
  grep -q "update-check.sh" "$sf" 2>/dev/null && return 0
  $PYTHON -c "
import json, sys
sf, cmd = sys.argv[1], sys.argv[2]
cfg = json.load(open(sf))
hooks = cfg.setdefault('hooks', {})
ss = hooks.setdefault('SessionStart', [])
ss.append({'hooks': [{'type': 'command', 'command': cmd, 'timeout': 30}]})
json.dump(cfg, open(sf, 'w'), indent=2, ensure_ascii=False)
print('\n')
" "$sf" "$cmd" 2>/dev/null
  ok "SessionStart hook 등록"
}
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python3)
_register_session_start "$TARGET_DIR/settings.json"

# ── .gitignore managed block 동기화 ──────────────────────────
if [ -n "$REPO_ROOT" ]; then
  DOCS_GIT_TRACK=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('docs_git_track', False))" "$CONFIG_FILE" 2>/dev/null || echo "False")

  GITIGNORE_FILE="$REPO_ROOT/.gitignore"
  GITIGNORE_START="# --- ai-bouncer start ---"
  GITIGNORE_END="# --- ai-bouncer end ---"

  # managed block 생성
  GITIGNORE_BLOCK="${GITIGNORE_START}
# ai-bouncer runtime artifacts
.claude/ai-bouncer/.version-checked
.claude/**/*.backup-*"

  if [ "$DOCS_GIT_TRACK" = "False" ] || [ "$DOCS_GIT_TRACK" = "false" ]; then
    GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
docs/"
  fi

  # bouncer installed files (manifest 기반 — 사용자 파일과 정확히 구분)
  if [ -f "$MANIFEST" ]; then
    MANIFEST_LINES=$(python3 -c "
import json, sys, os
files = json.load(open(sys.argv[1])).get('files', [])
# 절대경로·비정상 경로 제외 (구버전 manifest 방어)
valid = [f for f in files if f and not os.path.isabs(f)]
print('\n'.join('.claude/' + f for f in valid))
" "$MANIFEST" 2>/dev/null || echo "")
    if [ -n "$MANIFEST_LINES" ]; then
      GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
# ai-bouncer installed files
${MANIFEST_LINES}
update.sh
uninstall.sh"
    fi
  fi

  GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
${GITIGNORE_END}"

  if [ -f "$GITIGNORE_FILE" ]; then
    if grep -qF "$GITIGNORE_START" "$GITIGNORE_FILE"; then
      # 기존 블록 교체
      python3 - "$GITIGNORE_FILE" "$GITIGNORE_BLOCK" "$GITIGNORE_START" "$GITIGNORE_END" <<'PYEOF'
import sys
path = sys.argv[1]
block = sys.argv[2]
start = sys.argv[3]
end = sys.argv[4]
content = open(path, encoding='utf-8').read()
s = content.find(start)
e = content.find(end)
if s != -1 and e != -1:
    content = content[:s] + block + content[e + len(end):]
open(path, 'w', encoding='utf-8').write(content)
PYEOF
      ok ".gitignore managed block 동기화됨"
    else
      # 기존 파일 끝에 append
      printf '\n%s\n' "$GITIGNORE_BLOCK" >> "$GITIGNORE_FILE"
      ok ".gitignore managed block 추가됨"
    fi
  else
    # 신규 생성
    printf '%s\n' "$GITIGNORE_BLOCK" > "$GITIGNORE_FILE"
    ok ".gitignore 생성 + managed block 주입"
  fi
  UPDATED=$((UPDATED + 1))
fi

# 매니페스트 업데이트 (로컬 우선)
MANIFEST="$BOUNCER_DATA_DIR/manifest.json"
mkdir -p "$BOUNCER_DATA_DIR"
SHA=$(git -C "$PACKAGE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
python3 -c "
import json, datetime, os, sys
manifest_path = sys.argv[1]
sha = sys.argv[2]
m = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {}
m['version'] = sha
m['updated_at'] = datetime.datetime.now().isoformat()
json.dump(m, open(manifest_path,'w'), indent=2)
" "$MANIFEST" "$SHA"
ok "매니페스트 ($SHA)"
UPDATED=$((UPDATED + 1))

echo ""
echo -e "${GREEN}✓${NC}  ${BOLD}업데이트 완료${NC} — ${GREEN}${UPDATED}개 업데이트${NC}, ${DIM}${UNCHANGED}개 변경 없음${NC}"
