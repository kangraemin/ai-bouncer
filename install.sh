#!/bin/bash
# ai-bouncer install/update/uninstall
# Usage:
#   bash install.sh            — 신규 설치 또는 업데이트
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

# PACKAGE_DIR 유효성 검사 (curl 원격 실행 대응)
if [ ! -f "$PACKAGE_DIR/agents/intent.md" ]; then
  info "원격 실행 감지 — 레포를 다운로드합니다..."
  TMPDIR_INSTALL=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_INSTALL"' EXIT
  git clone --depth 1 "${AI_BOUNCER_REPO:-https://github.com/kangraemin/ai-bouncer.git}" "$TMPDIR_INSTALL/ai-bouncer" -q
  PACKAGE_DIR="$TMPDIR_INSTALL/ai-bouncer"
  ok "다운로드 완료"
fi

MODE="${1:-install}"
CI_MODE="${CI:-false}"  # CI=true 또는 --ci 로 비대화형 모드
SCOPE_OVERRIDE=""
[ "$MODE" = "--ci" ] && { CI_MODE=true; MODE=install; }
[ "$MODE" = "--global" ] && { SCOPE_OVERRIDE=global; MODE=install; }
# 두 번째 인자도 체크
[ "${2:-}" = "--global" ] && SCOPE_OVERRIDE=global
[ "${2:-}" = "--ci" ] && CI_MODE=true

# ── 언인스톨 ──────────────────────────────────────────────────
if [ "$MODE" = "--uninstall" ]; then
  bash "$PACKAGE_DIR/uninstall.sh"
  exit 0
fi

# ── --config 모드 ──────────────────────────────────────────────
if [ "$MODE" = "--config" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  CONFIG_FILE="${REPO_ROOT:-.}/.claude/ai-bouncer/config.json"
  TARGET_DIR="${REPO_ROOT:-.}/.claude"
  SETTINGS_FILE="$TARGET_DIR/settings.json"
  if [ ! -f "$CONFIG_FILE" ]; then
    err "ai-bouncer가 설치되어 있지 않습니다. 먼저 install.sh를 실행하세요."
    exit 1
  fi

  header "커밋 전략 재설정"
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

  header "실행 모드 재설정"
  echo "  1) hooks       — hook이 워크플로우를 강제 (기본값)"
  echo "  2) prompt-only — hook 없이 프롬프트로만 가이드"
  echo ""
  printf "  선택 [1]: "
  read -r ENFORCEMENT_CHOICE
  ENFORCEMENT_CHOICE="${ENFORCEMENT_CHOICE:-1}"
  case "$ENFORCEMENT_CHOICE" in
    2) ENFORCEMENT_MODE="prompt-only" ;;
    *) ENFORCEMENT_MODE="hooks" ;;
  esac

  header "에이전트 모드 재설정"
  echo "  1) team      — TeamCreate로 팀 구성 (기본값)"
  echo "  2) subagent  — Agent 도구로 서브에이전트 스폰"
  echo "  3) single    — 에이전트 없이 Main Claude가 직접 수행"
  echo ""
  printf "  선택 [1]: "
  read -r AGENT_CHOICE
  AGENT_CHOICE="${AGENT_CHOICE:-1}"
  case "$AGENT_CHOICE" in
    2) AGENT_MODE="subagent" ;;
    3) AGENT_MODE="single" ;;
    *) AGENT_MODE="team" ;;
  esac

  python3 - "$CONFIG_FILE" "$COMMIT_STRATEGY" "$COMMIT_SKILL_BOOL" "$ENFORCEMENT_MODE" "$AGENT_MODE" "$SETTINGS_FILE" "$TARGET_DIR" <<'PYEOF'
import json, sys, os

cfg_file = sys.argv[1]
strategy = sys.argv[2]
skill = sys.argv[3] == "true"
enforcement_mode = sys.argv[4]
agent_mode = sys.argv[5]
settings_file = sys.argv[6]
target_dir = sys.argv[7]

# config.json 업데이트
with open(cfg_file) as f: cfg = json.load(f)
old_enforcement = cfg.get('enforcement_mode', 'hooks')
old_agent_mode = cfg.get('agent_mode', 'team')
cfg["commit_strategy"] = strategy
cfg["commit_skill"] = skill
cfg["enforcement_mode"] = enforcement_mode
cfg["agent_mode"] = agent_mode
with open(cfg_file, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  commit_strategy   = {strategy}")
print(f"  commit_skill      = {skill}")
print(f"  enforcement_mode  = {enforcement_mode}")
print(f"  agent_mode        = {agent_mode}")

# settings.json 업데이트 (hook 등록/제거 + env)
if not os.path.exists(settings_file):
    settings = {}
else:
    with open(settings_file) as f: settings = json.load(f)

hooks = settings.setdefault('hooks', {})
env = settings.setdefault('env', {})

# --- Hook 등록/제거 ---
BOUNCER_HOOKS = ['plan-gate.sh', 'bash-gate.sh', 'doc-reminder.sh', 'bash-audit.sh',
                 'completion-gate.sh', 'subagent-track.sh', 'subagent-cleanup.sh']

def remove_bouncer_hooks():
    for hook_type in list(hooks.keys()):
        filtered = []
        for group in hooks[hook_type]:
            has_bouncer = any(
                any(bh in h.get('command', '') for bh in BOUNCER_HOOKS)
                for h in group.get('hooks', [])
            )
            if not has_bouncer:
                filtered.append(group)
        hooks[hook_type] = filtered
        if not hooks[hook_type]:
            del hooks[hook_type]

def add_hook(hook_type, matcher, cmd):
    hook_list = hooks.setdefault(hook_type, [])
    cmd_path = os.path.join(target_dir, 'ai-bouncer', 'hooks', cmd)
    already = any(cmd in h.get('command', '') for g in hook_list for h in g.get('hooks', []))
    if not already:
        entry = {'hooks': [{'type': 'command', 'command': cmd_path}]}
        if matcher:
            entry['matcher'] = matcher
        hook_list.append(entry)

if old_enforcement != enforcement_mode:
    if enforcement_mode == 'prompt-only':
        remove_bouncer_hooks()
        print("  ✓ settings.json: hook 전부 제거됨")
    else:
        # hooks.json 매니페스트 기반 등록
        hooks_manifest_path = os.path.join(target_dir, 'ai-bouncer', 'hooks', 'hooks.json')
        if os.path.exists(hooks_manifest_path):
            manifest = json.load(open(hooks_manifest_path))
            for hook_type, hook_entries in manifest.items():
                for entry in hook_entries:
                    matcher = entry.get('matcher')
                    add_hook(hook_type, matcher, entry['file'])
        else:
            # fallback: 하드코딩
            add_hook('PreToolUse', 'Write|Edit|MultiEdit', 'plan-gate.sh')
            add_hook('PreToolUse', 'Bash', 'bash-gate.sh')
            add_hook('PostToolUse', 'Write|Edit|MultiEdit', 'doc-reminder.sh')
            add_hook('PostToolUse', 'Bash', 'bash-audit.sh')
            add_hook('Stop', None, 'completion-gate.sh')
            add_hook('Stop', None, 'stop-active-cleanup.sh')
            add_hook('SubagentStart', None, 'subagent-track.sh')
            add_hook('SubagentStop', None, 'subagent-cleanup.sh')
        print("  ✓ settings.json: hook 재등록됨")

# --- Agent Teams env ---
if agent_mode == 'team':
    env['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
    print("  ✓ env: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1")
else:
    env.pop('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS', None)
    print(f"  ✓ env: AGENT_TEAMS 제거 (agent_mode={agent_mode})")

# SessionStart: auto-update hook 등록 (enforcement_mode 무관, 항상)
update_check_cmd = os.path.join(target_dir, 'ai-bouncer', 'scripts', 'update-check.sh')
ss = hooks.setdefault('SessionStart', [])
already_ss = any('update-check.sh' in h.get('command', '') for g in ss for h in g.get('hooks', []))
if not already_ss:
    ss.append({'hooks': [{'type': 'command', 'command': update_check_cmd, 'timeout': 30}]})
    print("  ✓ SessionStart hook 등록 (auto-update)")

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF
  ok "설정 업데이트 완료"
  exit 0
fi

# ── 설치 범위 ──────────────────────────────────────────────────
header "설치 범위"

# --global 플래그 또는 CI 환경변수로 전역 설치
SCOPE_CHOICE=""
if [ "${SCOPE_OVERRIDE:-}" = "global" ]; then
  SCOPE_CHOICE="1"
elif [ "$CI_MODE" = "true" ]; then
  SCOPE_CHOICE="${SCOPE_DEFAULT:-2}"  # CI 기본: 로컬
elif [ "$MODE" = "install" ]; then
  echo "  1) 전역 (~/.claude/) — 모든 프로젝트에 적용"
  echo "  2) 로컬 (.claude/)  — 현재 프로젝트에만 적용"
  echo ""
  printf "선택 [2]: "
  read -r SCOPE_CHOICE
  SCOPE_CHOICE="${SCOPE_CHOICE:-2}"
fi

REPO_ROOT=""
IS_SOURCE_REPO=false

if [ "$SCOPE_CHOICE" = "1" ]; then
  SCOPE="global"
  TARGET_DIR="$HOME/.claude"
  ok "전역 설치: $TARGET_DIR"
else
  SCOPE="local"
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -z "$REPO_ROOT" ]; then
    warn "git 레포가 아닙니다. git init을 실행합니다."
    git init -q .
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -z "$REPO_ROOT" ]; then
      err "에러: git init에 실패했습니다."
      exit 1
    fi
    ok "git init 완료: $REPO_ROOT"
  fi
  TARGET_DIR="$REPO_ROOT/.claude"
  # 소스 레포 감지: 소스 레포에서는 update.sh/uninstall.sh를 설치 아티팩트로 취급하지 않음
  if [ -f "$REPO_ROOT/install.sh" ] && [ -f "$REPO_ROOT/agents/intent.md" ]; then
    IS_SOURCE_REPO=true
  fi
fi

info "설치 대상: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# 기존 설치 감지
BOUNCER_DATA_DIR="$TARGET_DIR/ai-bouncer"
MANIFEST="$BOUNCER_DATA_DIR/manifest.json"
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
  INSTALLED_FILES+=("$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$dst" "$TARGET_DIR" 2>/dev/null || echo "$dst")")
  ok "$(basename "$dst")"
}

# skills 디렉토리 설치 (TARGET_DIR 기준)
install_skill() {
  local src_dir="$1" skill_name="$2"
  local dst_dir="${TARGET_DIR}/skills/${skill_name}"
  mkdir -p "$dst_dir"
  cp -r "$src_dir/." "$dst_dir/"
  for f in "$src_dir"/*; do
    [ -f "$f" ] && INSTALLED_FILES+=("$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "${dst_dir}/$(basename "$f")" "$TARGET_DIR" 2>/dev/null || echo "skills/${skill_name}/$(basename "$f")")")
  done
  ok "${skill_name} (skill)"
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
  INSTALLED_FILES+=("$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$dst" "$TARGET_DIR" 2>/dev/null || echo "$dst")")
}

# ── 파일 설치 ──────────────────────────────────────────────────
header "파일 설치"

# agents (동적 복사 — agents/*.md)
for agent in "$PACKAGE_DIR/agents/"*.md; do
  [ -f "$agent" ] || continue
  copy_file "$agent" "$TARGET_DIR/agents/$(basename "$agent")"
done

# agents 서브디렉토리 (guides/ 등) 동적 복사
for subdir in "$PACKAGE_DIR/agents"/*/; do
  [ -d "$subdir" ] || continue
  dir_name=$(basename "$subdir")
  mkdir -p "$TARGET_DIR/agents/$dir_name"
  for f in "$subdir"*.md; do
    [ -f "$f" ] || continue
    copy_file "$f" "$TARGET_DIR/agents/$dir_name/$(basename "$f")"
  done
done

# 소스에서 제거된 agent 파일: 삭제하지 않고 유지 (사용자 파일 보호)
# manifest는 INSTALLED_FILES 기반으로 자동 갱신되므로 별도 처리 불필요

# skills (로컬 .claude/skills/ 에 설치 — 동적)
for skill_src in "$PACKAGE_DIR/skills"/*/; do
  [ -d "$skill_src" ] || continue
  skill_name=$(basename "$skill_src")
  install_skill "$skill_src" "$skill_name"
done

# ── 마이그레이션: 구 경로 → BOUNCER_DATA_DIR ──────────────────
if [ "$IS_UPDATE" = true ] && [ -f "$PACKAGE_DIR/hooks/hooks.json" ]; then
  OLD_HOOKS_DIR="$TARGET_DIR/hooks"
  OLD_SCRIPTS_DIR="$TARGET_DIR/scripts"

  # 구 경로에 bouncer hook이 하나라도 있는지 확인
  _need_migrate=false
  while read -r _mfile; do
    if [ -f "$OLD_HOOKS_DIR/$_mfile" ]; then
      _need_migrate=true
      break
    fi
  done < <(python3 -c "
import json, sys
manifest = json.load(open(sys.argv[1]))
for hooks in manifest.values():
    for h in hooks:
        print(h['file'])
" "$PACKAGE_DIR/hooks/hooks.json")

  if [ "$_need_migrate" = true ]; then
    header "마이그레이션: hooks/scripts → ai-bouncer/"
    mkdir -p "$BOUNCER_DATA_DIR/hooks" "$BOUNCER_DATA_DIR/hooks/lib" "$BOUNCER_DATA_DIR/scripts"

    # 1) bouncer hook 파일 이동
    while read -r _mfile; do
      if [ -f "$OLD_HOOKS_DIR/$_mfile" ] && [ ! -f "$BOUNCER_DATA_DIR/hooks/$_mfile" ]; then
        mv "$OLD_HOOKS_DIR/$_mfile" "$BOUNCER_DATA_DIR/hooks/$_mfile"
        echo "  ✓ 이동: hooks/$_mfile → ai-bouncer/hooks/$_mfile"
      fi
    done < <(python3 -c "
import json, sys
manifest = json.load(open(sys.argv[1]))
for hooks in manifest.values():
    for h in hooks:
        print(h['file'])
" "$PACKAGE_DIR/hooks/hooks.json")

    # 2) hooks.json 이동
    if [ -f "$OLD_HOOKS_DIR/hooks.json" ] && [ ! -f "$BOUNCER_DATA_DIR/hooks/hooks.json" ]; then
      mv "$OLD_HOOKS_DIR/hooks.json" "$BOUNCER_DATA_DIR/hooks/hooks.json"
      echo "  ✓ 이동: hooks/hooks.json → ai-bouncer/hooks/hooks.json"
    fi

    # 3) hooks/lib/ bouncer lib 이동
    if [ -d "$OLD_HOOKS_DIR/lib" ]; then
      for _lib in "$OLD_HOOKS_DIR/lib/"*.sh; do
        [ -f "$_lib" ] || continue
        _libname=$(basename "$_lib")
        if [ ! -f "$BOUNCER_DATA_DIR/hooks/lib/$_libname" ]; then
          mv "$_lib" "$BOUNCER_DATA_DIR/hooks/lib/$_libname"
          echo "  ✓ 이동: hooks/lib/$_libname → ai-bouncer/hooks/lib/$_libname"
        fi
      done
    fi

    # 4) scripts/update-check.sh 이동
    if [ -f "$OLD_SCRIPTS_DIR/update-check.sh" ] && [ ! -f "$BOUNCER_DATA_DIR/scripts/update-check.sh" ]; then
      mv "$OLD_SCRIPTS_DIR/update-check.sh" "$BOUNCER_DATA_DIR/scripts/update-check.sh"
      echo "  ✓ 이동: scripts/update-check.sh → ai-bouncer/scripts/update-check.sh"
    fi

    # 5) 빈 디렉토리 정리 (non-bouncer 파일 있으면 유지)
    [ -d "$OLD_HOOKS_DIR/lib" ] && rmdir "$OLD_HOOKS_DIR/lib" 2>/dev/null || true
    [ -d "$OLD_HOOKS_DIR" ] && rmdir "$OLD_HOOKS_DIR" 2>/dev/null || true
    [ -d "$OLD_SCRIPTS_DIR" ] && rmdir "$OLD_SCRIPTS_DIR" 2>/dev/null || true
  fi
fi

# hooks.json 매니페스트 기반 동적 설치
HOOKS_MANIFEST="$PACKAGE_DIR/hooks/hooks.json"
if [ -f "$HOOKS_MANIFEST" ]; then
  # hooks.json 자체도 복사
  mkdir -p "$BOUNCER_DATA_DIR/hooks"
  copy_file "$HOOKS_MANIFEST" "$BOUNCER_DATA_DIR/hooks/hooks.json"

  # process substitution으로 subshell 회피 (INSTALLED_FILES 전파)
  while read -r htype hfile; do
    src="$PACKAGE_DIR/hooks/$hfile"
    dst="$BOUNCER_DATA_DIR/hooks/$hfile"
    [ -f "$src" ] || continue
    if [ "$htype" = "managed" ]; then
      install_hook "$src" "$dst"
    else
      copy_file "$src" "$dst"
      chmod +x "$dst"
    fi
  done < <(python3 -c "
import json, sys
manifest = json.load(open(sys.argv[1]))
for hook_type, hooks in manifest.items():
    for h in hooks:
        print(h['type'], h['file'])
" "$HOOKS_MANIFEST")
fi

# hooks/lib/ 동적 복사
if [ -d "$PACKAGE_DIR/hooks/lib" ]; then
  mkdir -p "$BOUNCER_DATA_DIR/hooks/lib"
  for lib in "$PACKAGE_DIR/hooks/lib/"*.sh; do
    [ -f "$lib" ] || continue
    copy_file "$lib" "$BOUNCER_DATA_DIR/hooks/lib/$(basename "$lib")"
    chmod +x "$BOUNCER_DATA_DIR/hooks/lib/$(basename "$lib")"
  done
fi

# scripts/ 동적 복사
if [ -d "$PACKAGE_DIR/scripts" ]; then
  mkdir -p "$BOUNCER_DATA_DIR/scripts"
  for script in "$PACKAGE_DIR/scripts/"*.sh; do
    [ -f "$script" ] || continue
    copy_file "$script" "$BOUNCER_DATA_DIR/scripts/$(basename "$script")"
    chmod +x "$BOUNCER_DATA_DIR/scripts/$(basename "$script")"
  done
fi

# update.sh / uninstall.sh
if [ "$SCOPE" = "global" ]; then
  cp "$PACKAGE_DIR/update.sh" "$TARGET_DIR/update.sh"
  chmod +x "$TARGET_DIR/update.sh"
  ok "update.sh ($TARGET_DIR)"
  cp "$PACKAGE_DIR/uninstall.sh" "$TARGET_DIR/uninstall.sh"
  chmod +x "$TARGET_DIR/uninstall.sh"
  ok "uninstall.sh ($TARGET_DIR)"
else
  cp "$PACKAGE_DIR/update.sh" "$REPO_ROOT/update.sh"
  chmod +x "$REPO_ROOT/update.sh"
  ok "update.sh (프로젝트 루트)"
  cp "$PACKAGE_DIR/uninstall.sh" "$REPO_ROOT/uninstall.sh"
  chmod +x "$REPO_ROOT/uninstall.sh"
  ok "uninstall.sh (프로젝트 루트)"
fi

# ── .ai-bouncer-tasks git 추적 설정 ──────────────────────────────
DOCS_TRACK_BOOL="false"
if [ "$SCOPE" = "global" ]; then
  DOCS_GIT_TRACK="n"
  ok ".ai-bouncer-tasks/ git 추적 — 전역 모드에서는 해당 없음"
elif [ "$CI_MODE" = "true" ]; then
  DOCS_GIT_TRACK="n"
  ok ".ai-bouncer-tasks/ git 미추적 (CI 기본값)"
else
  header ".ai-bouncer-tasks/ 설정"
  echo "  ai-bouncer는 작업별로 .ai-bouncer-tasks/<task-name>/ 폴더에 산출물을 저장합니다."
  echo ""
  printf "  .ai-bouncer-tasks/ 폴더를 git으로 추적할까요? (y/n) [n]: "
  read -r DOCS_GIT_TRACK
  DOCS_GIT_TRACK="${DOCS_GIT_TRACK:-n}"
  if [[ "$DOCS_GIT_TRACK" =~ ^[yY] ]]; then
    DOCS_TRACK_BOOL="true"
    ok ".ai-bouncer-tasks/ git 추적 활성화"
  else
    ok ".ai-bouncer-tasks/ git 미추적 (기본값)"
  fi
fi

# ── .gitignore managed block 주입 (로컬 전용) ─────────────────
if [ "$SCOPE" = "local" ]; then
header ".gitignore 설정"

GITIGNORE_FILE="$REPO_ROOT/.gitignore"
GITIGNORE_START="# --- ai-bouncer start ---"
GITIGNORE_END="# --- ai-bouncer end ---"

# managed block 생성
GITIGNORE_BLOCK="${GITIGNORE_START}
# ai-bouncer runtime artifacts
.claude/ai-bouncer/.version-checked
.claude/ai-bouncer/config.json
.claude/ai-bouncer/manifest.json
.claude/**/*.backup-*
.claude/settings.json"

if [ "$DOCS_TRACK_BOOL" = "false" ]; then
  GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
.ai-bouncer-tasks/"
fi

# bouncer installed files (manifest 기반 — 사용자 파일과 정확히 구분)
GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
# ai-bouncer installed files"
for f in "${INSTALLED_FILES[@]}"; do
  # 절대경로·비정상 경로 제외 (방어)
  [[ "$f" = /* ]] && continue
  GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
.claude/${f}"
done
if [ "$IS_SOURCE_REPO" = false ]; then
  GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
update.sh
uninstall.sh"
fi

GITIGNORE_BLOCK="${GITIGNORE_BLOCK}
${GITIGNORE_END}"

if [ -f "$GITIGNORE_FILE" ]; then
  EXISTING=$(cat "$GITIGNORE_FILE")
  if echo "$EXISTING" | grep -qF "$GITIGNORE_START"; then
    # 기존 블록 교체 (sed로 start~end 사이 교체)
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
    ok ".gitignore managed block 교체됨"
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

# 이미 추적 중인 bouncer 파일 untrack
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
  for f in "${INSTALLED_FILES[@]}"; do
    [[ "$f" = /* ]] && continue
    git -C "$REPO_ROOT" rm --cached ".claude/$f" 2>/dev/null || true
  done
  if [ "$IS_SOURCE_REPO" = false ]; then
    git -C "$REPO_ROOT" rm --cached update.sh uninstall.sh 2>/dev/null || true
  fi
fi
fi # SCOPE=local .gitignore 블록 끝

# 커밋 전략 선택
header "커밋 전략"
if [ "$CI_MODE" = "true" ]; then
  COMMIT_CHOICE="1"
else
  echo "  Step/Phase 완료 시 자동 커밋 전략을 선택하세요."
  echo ""
  echo "  1) per-step  — Step 완료마다 즉시 커밋 + 푸시 (기본값)"
  echo "  2) per-phase — 개발 Phase 전체 완료 시 커밋 + 푸시"
  echo "  3) none      — 커밋하지 않음 (수동 관리)"
  echo ""
  printf "  선택 [1]: "
  read -r COMMIT_CHOICE
  COMMIT_CHOICE="${COMMIT_CHOICE:-1}"
fi
case "$COMMIT_CHOICE" in
  2) COMMIT_STRATEGY="per-phase" ;;
  3) COMMIT_STRATEGY="none" ;;
  *) COMMIT_STRATEGY="per-step" ;;
esac

# 커밋 스킬 감지 (commands/ 또는 skills/ 방식 모두 지원)
COMMIT_SKILL_BOOL="false"
for _commit_path in \
  "$HOME/.claude/commands/commit.md" \
  "$HOME/.claude/skills/commit/SKILL.md" \
  ".claude/commands/commit.md" \
  ".claude/skills/commit/SKILL.md"; do
  if [ -f "$_commit_path" ]; then
    COMMIT_SKILL_BOOL="true"
    ok "커밋 스킬 감지됨 ($_commit_path) — 커밋 시 /commit 스킬 활용"
    break
  fi
done
if [ "$COMMIT_SKILL_BOOL" = "false" ]; then
  ok "커밋 스킬 없음 — 일반 git commit 사용"
fi
ok "커밋 전략: $COMMIT_STRATEGY"

# 실행 모드 선택
header "실행 모드"
if [ "$CI_MODE" = "true" ]; then
  ENFORCEMENT_MODE="${ENFORCEMENT_MODE:-hooks}"
else
  echo "  1) hooks       — hook이 워크플로우를 강제 (기본값)"
  echo "  2) prompt-only — hook 없이 프롬프트로만 가이드"
  echo ""
  printf "  선택 [1]: "
  read -r ENFORCEMENT_CHOICE
  ENFORCEMENT_CHOICE="${ENFORCEMENT_CHOICE:-1}"
  case "$ENFORCEMENT_CHOICE" in
    2) ENFORCEMENT_MODE="prompt-only" ;;
    *) ENFORCEMENT_MODE="hooks" ;;
  esac
fi
ok "실행 모드: $ENFORCEMENT_MODE"

# 에이전트 모드 선택
header "에이전트 모드"
if [ "$CI_MODE" = "true" ]; then
  AGENT_MODE="${AGENT_MODE:-team}"
else
  echo "  1) team      — TeamCreate로 팀 구성 (기본값)"
  echo "  2) subagent  — Agent 도구로 서브에이전트 스폰"
  echo "  3) single    — 에이전트 없이 Main Claude가 직접 수행"
  echo ""
  printf "  선택 [1]: "
  read -r AGENT_CHOICE
  AGENT_CHOICE="${AGENT_CHOICE:-1}"
  case "$AGENT_CHOICE" in
    2) AGENT_MODE="subagent" ;;
    3) AGENT_MODE="single" ;;
    *) AGENT_MODE="team" ;;
  esac
fi
ok "에이전트 모드: $AGENT_MODE"

# config.json 저장
mkdir -p "$BOUNCER_DATA_DIR"
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

python3 - "$SETTINGS_FILE" "$TARGET_DIR" "$ENFORCEMENT_MODE" "$AGENT_MODE" "$PACKAGE_DIR/hooks/hooks.json" <<'PYEOF'
import json, sys, os

settings_file = sys.argv[1]
target_dir = sys.argv[2]
enforcement_mode = sys.argv[3]
agent_mode = sys.argv[4]
hooks_manifest_path = sys.argv[5]

cfg = {}
if os.path.exists(settings_file):
    with open(settings_file, encoding='utf-8') as f:
        cfg = json.load(f)

hooks = cfg.setdefault('hooks', {})

# Agent Teams env 설정 (team 모드에서만 필요)
env = cfg.setdefault('env', {})
if agent_mode == 'team':
    if env.get('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS') != '1':
        env['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
        print('  ✓ env 설정: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1')
    else:
        print('  · env 이미 설정됨: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1')
else:
    if 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' in env:
        env.pop('CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS')
        print('  ✓ env 제거: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (agent_mode != team)')
    else:
        print(f'  · AGENT_TEAMS env 불필요 (agent_mode={agent_mode})')

def is_registered(hook_list, cmd_fragment):
    for group in hook_list:
        for h in group.get('hooks', []):
            if cmd_fragment in h.get('command', ''):
                return True
    return False

def add_hook(hook_type, matcher, cmd):
    hook_list = hooks.setdefault(hook_type, [])
    cmd_path = os.path.join(target_dir, 'ai-bouncer', 'hooks', cmd)
    if not is_registered(hook_list, cmd):
        entry = {'hooks': [{'type': 'command', 'command': cmd_path}]}
        if matcher:
            entry['matcher'] = matcher
        hook_list.append(entry)
        print(f"  ✓ {hook_type} hook 등록: {cmd}")
    else:
        print(f"  · {hook_type} hook 이미 등록됨: {cmd}")

# hooks.json 매니페스트 기반 등록
if enforcement_mode == 'hooks' and os.path.exists(hooks_manifest_path):
    manifest = json.load(open(hooks_manifest_path))
    for hook_type, hook_entries in manifest.items():
        for entry in hook_entries:
            matcher = entry.get('matcher')
            add_hook(hook_type, matcher, entry['file'])
else:
    print('  · hook 등록 스킵 (enforcement_mode=prompt-only)')

# SessionStart hook: update-check.sh (enforcement_mode 무관)
update_cmd = os.path.join(target_dir, 'ai-bouncer', 'scripts', 'update-check.sh')
ss_list = hooks.setdefault('SessionStart', [])
if not is_registered(ss_list, 'update-check.sh'):
    ss_list.append({'hooks': [{'type': 'command', 'command': update_cmd, 'timeout': 30}]})
    print(f"  ✓ SessionStart hook 등록: update-check.sh")
else:
    print(f"  · SessionStart hook 이미 등록됨: update-check.sh")

# permissions.allow에 Read/Glob/Grep 추가 (multi-agent 권한 프롬프트 방지)
perms = cfg.setdefault('permissions', {})
allow = perms.setdefault('allow', [])
for tool in ['Read', 'Glob', 'Grep']:
    if tool not in allow:
        allow.append(tool)
        print(f"  ✓ permissions.allow 추가: {tool}")
    else:
        print(f"  · permissions.allow 이미 있음: {tool}")

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write('\n')
PYEOF

# ── Stop hook 호환성 패치 ──────────────────────────────────────
header "Stop hook 호환성"

inject_stop_compat() {
  local src="$1" dst="$2"
  local START="# --- ai-bouncer start ---"
  local END="# --- ai-bouncer end ---"

  [ -f "$dst" ] || return 0

  python3 - "$src" "$dst" "$START" "$END" <<'PYEOF'
import sys

src_path     = sys.argv[1]
dst_path     = sys.argv[2]
start_marker = sys.argv[3]
end_marker   = sys.argv[4]

src = open(src_path, encoding='utf-8').read()
dst = open(dst_path, encoding='utf-8').read()

# managed block 추출
s_start = src.find(start_marker)
s_end   = src.find(end_marker)
if s_start == -1 or s_end == -1:
    sys.exit(0)
managed_block = src[s_start : s_end + len(end_marker)]

# 기존 블록 교체
d_start = dst.find(start_marker)
d_end   = dst.find(end_marker)
if d_start != -1 and d_end != -1:
    new_dst = dst[:d_start] + managed_block + dst[d_end + len(end_marker):]
else:
    # shebang 뒤에 inject (stdin을 먼저 읽어야 하므로 최상단)
    if dst.startswith('#!'):
        newline = dst.index('\n') + 1
        new_dst = dst[:newline] + managed_block + '\n' + dst[newline:]
    else:
        new_dst = managed_block + '\n' + dst

open(dst_path, 'w', encoding='utf-8').write(new_dst)
print(f"  ✓ {dst_path}: ai-bouncer compat block inject")
PYEOF
  ok "$(basename "$dst") (stop compat)"
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
      completion-gate.sh|subagent-track.sh|subagent-cleanup.sh|stop-active-cleanup.sh) continue ;;
    esac
    inject_stop_compat "$PACKAGE_DIR/hooks/stop-bouncer-compat.sh" "$hook_path"
  done <<< "$stop_hooks"
}

patch_stop_hooks "$HOME/.claude/settings.json"
patch_stop_hooks "$TARGET_DIR/settings.json"

# ── 매니페스트 업데이트 ────────────────────────────────────────
header "매니페스트 기록"

mkdir -p "$BOUNCER_DATA_DIR"
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

# ── 백업 파일 정리 ──────────────────────────────────────────────
BACKUP_COUNT=0
while IFS= read -r -d '' backup; do
  rm -f "$backup"
  BACKUP_COUNT=$((BACKUP_COUNT + 1))
done < <(find "$TARGET_DIR" -name "*.backup-*" -print0 2>/dev/null)
[ "$BACKUP_COUNT" -gt 0 ] && ok "${BACKUP_COUNT}개 백업 파일 정리됨"

# ── 완료 ──────────────────────────────────────────────────────
header "설치 완료"
echo -e "  ${BOLD}설정 요약${NC}"
echo "  ├─ 범위: $SCOPE ($TARGET_DIR)"
echo "  ├─ agents: $(ls "$TARGET_DIR/agents/"*.md 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
echo "  ├─ skills: dev-bounce ($TARGET_DIR/skills/dev-bounce/)"
echo "  ├─ hooks: plan-gate.sh (PreToolUse: Write/Edit)"
echo "  │         bash-gate.sh (PreToolUse: Bash)"
echo "  │         doc-reminder.sh (PostToolUse: Write/Edit)"
echo "  │         bash-audit.sh (PostToolUse: Bash)"
echo "  │         completion-gate.sh (Stop)"
echo "  │         subagent-track.sh (SubagentStart)"
echo "  │         subagent-cleanup.sh (SubagentStop)"
echo "  ├─ tasks git 추적: $DOCS_TRACK_BOOL"
echo "  ├─ 실행 모드: $ENFORCEMENT_MODE"
echo "  ├─ 에이전트 모드: $AGENT_MODE"
echo "  └─ 매니페스트: $BOUNCER_DATA_DIR/manifest.json"
echo ""
echo -e "  사용법: 프로젝트에서 ${BOLD}/dev-bounce <요청>${NC} 실행"
echo ""
warn "Claude Code를 재시작해야 새로 설치된 스킬이 활성화됩니다."
echo ""
ok "ai-bouncer 설치 완료!"
