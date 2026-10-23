#!/usr/bin/env bash
# bouncer init — 이 레포에 ai-bouncer 를 켠다 (레포 설정만 만든다. 엔진·훅은 전역).
#   bouncer init                  .claude/ai-bouncer/workflow.yaml, .gitignore, CLAUDE.md 규칙 블록
#   bouncer init --decline        이 레포에서는 켜지 않는다 (세션 시작 때 다시 묻지 않는다)
#   bouncer init --no-claude-md   CLAUDE.md 는 건드리지 않는다
#
# 옛 로컬 설치본(레포 안 engine/hooks, 프로젝트 settings.json 훅, 로컬 스킬)이 있으면 걷어낸다.
# 그대로 두면 전역 훅과 같이 돌거나, 옛 버전 엔진이 계속 돈다.

set -uo pipefail
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_D/lib/common.sh"

DECLINE=0; CLAUDE_MD=1; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --decline)      DECLINE=1; shift ;;
    --no-claude-md) CLAUDE_MD=0; shift ;;
    --quiet)        QUIET=1; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ai-bouncer: 알 수 없는 인자: %s\n' "$1" >&2; exit 1 ;;
  esac
done
die() { printf 'ai-bouncer: %s\n' "$1" >&2; exit 1; }
say() { [ "$QUIET" = 1 ] || printf "$@"; }

# git 레포 안이면 루트에 둔다. 서브디렉토리에 두면 하위에서만 켜진다.
# 단 루트까지 올라가는 사이에 이미 설정이 있으면 그 하위 프로젝트다 (모노레포의 frontend/ 등).
# 엔진도 가장 가까운 workflow.yaml 을 프로젝트로 보므로, 루트로 건너뛰면 그 설정은 정리되지 않는다.
TOP="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
TOP="$(cd "$TOP" && pwd -P)"
PROJECT="$TOP"; d="$(pwd -P)"
while :; do
  [ -f "$d/.claude/ai-bouncer/workflow.yaml" ] && { PROJECT="$d"; break; }
  [ "$d" = "$TOP" ] || [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
REG_DIR="$(bouncer_registry_dir)"

if [ "$DECLINE" = 1 ]; then
  mkdir -p "$REG_DIR" || die "목록 디렉토리를 만들지 못했다: $REG_DIR"
  { [ -f "$REG_DIR/declined" ] && cat "$REG_DIR/declined"; printf '%s\n' "$PROJECT"; } \
    | awk 'NF && !seen[$0]++' > "$REG_DIR/declined.tmp" && mv "$REG_DIR/declined.tmp" "$REG_DIR/declined"
  say '이 레포에서는 ai-bouncer를 켜지 않는다: %s\n켜려면: bouncer init\n' "$PROJECT"
  exit 0
fi

ROOT="$PROJECT/.claude"; DIR="$ROOT/ai-bouncer"
mkdir -p "$DIR" || die "디렉토리 생성 실패: $DIR"

# ── 1. 옛 로컬 설치본 정리 ───────────────────────────────────
# 옛 manifest.json 이 "우리가 .gitignore 에 넣었다"를 기억하고 있다 — 지우기 전에 읽는다.
GI_ADDED="$(cat "$DIR/init.json" "$DIR/manifest.json" 2>/dev/null | jq -r '.gitignore_added // false' 2>/dev/null | grep -m1 true || echo false)"
CLEANED=0
LEGACY_HOOKS=0; [ -d "$DIR/hooks" ] && LEGACY_HOOKS=1
for f in engine hooks bin scripts installed.json manifest.json .update-check .version-checked config.json; do
  [ -e "$DIR/$f" ] && { rm -rf "${DIR:?}/$f"; CLEANED=$((CLEANED+1)); }
done
# 이미 열려 있는 세션은 시작할 때 읽은 훅 경로(레포 안 hooks/*.sh)를 계속 부른다.
# 파일을 그냥 지우면 그 세션들은 훅 오류만 내고 게이트가 꺼진다 — 그 자리에 전역 훅으로 넘기는 얇은 파일을 둔다.
# 커밋 대상은 아니다 (.gitignore). 새 세션은 프로젝트 settings 에 등록이 없어 이 파일을 부르지 않는다.
if [ "$LEGACY_HOOKS" = 1 ]; then
  GH="$(cd "$_D/../hooks" && pwd)"
  mkdir -p "$DIR/hooks"
  for h in session-start pre-tool post-tool stop session-end; do
    printf '#!/usr/bin/env bash
# 옛 로컬 설치본 자리 — 이 경로로 훅을 잡아 둔 세션을 전역 훅으로 넘긴다.
BOUNCER_FORWARDED=1 exec bash "%s/%s.sh" "$@"
' "$GH" "$h" > "$DIR/hooks/$h.sh"
    chmod 755 "$DIR/hooks/$h.sh"
  done
  git -C "$PROJECT" rm -r -q --cached --ignore-unmatch -- .claude/ai-bouncer/hooks >/dev/null 2>&1 || true
fi
# 로컬 스킬은 전역 스킬과 이름이 같아 옛 내용이 이긴다
if [ -f "$ROOT/skills/dev-bounce/SKILL.md" ]; then
  rm -rf "$ROOT/skills/dev-bounce"; CLEANED=$((CLEANED+1))
  rmdir "$ROOT/skills" 2>/dev/null
fi
for sk in bouncer-status update-bouncer; do
  [ -d "$ROOT/skills/$sk" ] && { rm -rf "$ROOT/skills/$sk"; CLEANED=$((CLEANED+1)); }
done
# 아주 옛 버전이 깔던 위임 에이전트 정의
for ag in dev.md e2e-writer.md intent.md lead.md qa.md guides/tc-guide.md; do
  [ -f "$ROOT/agents/$ag" ] && { rm -f "$ROOT/agents/$ag"; CLEANED=$((CLEANED+1)); }
done
rmdir "$ROOT/agents/guides" "$ROOT/agents" 2>/dev/null
if [ -f "$PROJECT/uninstall.sh" ] && grep -q 'ai-bouncer uninstall' "$PROJECT/uninstall.sh" 2>/dev/null; then
  rm -f "$PROJECT/uninstall.sh"; CLEANED=$((CLEANED+1))
fi
# 프로젝트 settings.json 의 ai-bouncer 훅 — 이제 전역 settings 에 있다. 남의 훅·설정은 둔다.
SETTINGS="$ROOT/settings.json"
if [ -f "$SETTINGS" ]; then
  n="$(python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
except Exception:
    print(0); sys.exit(0)
hooks = cfg.get("hooks", {})
removed = 0
for event, arr in list(hooks.items()):
    for entry in list(arr):
        before = len(entry.get("hooks", []))
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "/.claude/ai-bouncer/" not in str(h.get("command", ""))]
        removed += before - len(entry["hooks"])
        if not entry["hooks"]:
            arr.remove(entry)
    if not arr:
        del hooks[event]
if not hooks:
    cfg.pop("hooks", None)
if removed:
    json.dump(cfg, open(p, "w"), ensure_ascii=False, indent=2)
print(removed)
PY
)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null && CLEANED=$((CLEANED+n))
  [ "$(jq -c . "$SETTINGS" 2>/dev/null)" = "{}" ] && rm -f "$SETTINGS"
fi
# 아주 옛 버전은 .claude/CLAUDE.md 에도 규칙 블록을 넣었다
OLD_CMD="$ROOT/CLAUDE.md"
if [ -f "$OLD_CMD" ] && grep -q 'ai-bouncer-rule start' "$OLD_CMD"; then
  python3 - "$OLD_CMD" <<'PYC'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*# --- ai-bouncer-rule start ---.*?# --- ai-bouncer-rule end ---\n*', '\n', s, flags=re.S)
open(p, 'w').write(s)
PYC
  [ -n "$(tr -d '[:space:]' < "$OLD_CMD" 2>/dev/null)" ] || rm -f "$OLD_CMD"
  CLEANED=$((CLEANED+1))
fi
[ "$CLEANED" -gt 0 ] && say '  옛 로컬 설치본 %d개 정리 (엔진·훅은 이제 전역)\n' "$CLEANED"

# ── 2. workflow.yaml ─────────────────────────────────────────
# 사용자 자산이다 — 기본값과 다른 것만 담는 override. 없으면 빈 것을 만든다.
# 옛 버전이 복사해 둔 "기본값 전체 사본"은 기본값과 같은 부분을 걷어낸다(원본은 .bak).
CREATED=0
if [ -f "$DIR/workflow.yaml" ]; then
  # -B: compile·legacy 를 import 하므로 바이트코드를 남기지 않는다 (설치본에 .pyc 가 커밋됐다)
  python3 -B "$_D/migrate-workflow.py" "$DIR/workflow.yaml" >/dev/null || true
else
  cat > "$DIR/workflow.yaml" <<'YML'
# ai-bouncer 레포 설정 — 이 레포에서 "작업 끝"이라고 하려면 통과해야 할 검사를 적는다.
# 단계 순서(구현 → 검증 → 마무리)와 기본 규칙은 전역 엔진에 있다. 여기엔 이 레포만 다른 것만 적는다.
#
# 보통은 verify 단계에 검사 명령 하나면 된다. 엔진이 직접 돌려 통과해야 끝난다:
# stages:
#   verify:
#     steps:
#       - label: 테스트
#         run: "npm test"
#         blocking: true
#
# 그 밖의 키(시작할 때 끌 수 있는 검사, 지시문 덧붙이기, 기본 step 빼기): docs/SCHEMA.md

version: 1
YML
  CREATED=1
fi

# ── 3. 런타임 상태를 gitignore ───────────────────────────────
# 이게 없으면 워킹트리가 항상 더러워서 finalize 게이트가 안 열린다.
if git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
  if ! grep -qxF '.ai-bouncer/' "$PROJECT/.gitignore" 2>/dev/null; then
    printf '\n# ai-bouncer 런타임 상태\n.ai-bouncer/\n' >> "$PROJECT/.gitignore"
    GI_ADDED=true
    say '  .gitignore에 .ai-bouncer/ 추가\n'
  fi
  # 설정 디렉토리 안에 섞여 있는 런타임 파일들. 커밋되면 세션마다 가짜 diff가 뜬다.
  printf 'workflow.compiled.json\nworkflow.yaml.bak*\n__pycache__/\nhooks/\n' > "$DIR/.gitignore"
fi

# ── 4. CLAUDE.md 규칙 블록 ───────────────────────────────────
# hook은 작업이 시작된 뒤에만 강제할 수 있다. 작업을 시작하게 만드는 것은 프롬프트 몫이다.
# 전역 CLAUDE.md 에 넣지 않는다 — 켜지 않은 레포에서도 /dev-bounce 를 하라고 하게 된다.
CMD_FILE="$PROJECT/CLAUDE.md"
if [ "$CLAUDE_MD" = 1 ]; then
  python3 - "$CMD_FILE" <<'PYM'
import os, re, sys
p = sys.argv[1]
block = """<!-- ai-bouncer:start -->
## ai-bouncer

코드 수정·기능 구현·버그 수정·리팩터링 등 **개발 작업은 `/dev-bounce`로 시작한다.**
스킬을 거치지 않고 Edit / Write / Bash로 소스를 고치지 않는다.

- 작업이 시작되면 hook이 단계별 규칙을 강제한다. 시작 전에는 아무것도 막지 않는다.
- 진행 중인 작업이 있는지 `bouncer status`로 먼저 확인하고, 있으면 이어서 한다.
- 질문·설명 요청은 해당 없다. 그냥 답하면 된다.
- hook이 차단하면 우회하지 말고 차단 사유에 적힌 조건을 충족시켜라.
<!-- ai-bouncer:end -->"""
s = open(p).read() if os.path.exists(p) else ""
if "<!-- ai-bouncer:start -->" in s:
    s = re.sub(r'<!-- ai-bouncer:start -->.*?<!-- ai-bouncer:end -->', lambda m: block, s, flags=re.S)
else:
    s = (s + ("\n" if s else "")) + block + "\n"
open(p, "w").write(s)
PYM
fi

# ── 5. 컴파일 + 기록 ─────────────────────────────────────────
python3 -B "$_D/compile.py" "$DIR/workflow.yaml" "$DIR/workflow.compiled.json" >/dev/null \
  || die "workflow.yaml 컴파일 실패 — bouncer check 로 확인하라"
# uninstall 이 우리가 넣은 .gitignore 줄만 되돌리려면 넣었다는 사실을 알아야 한다.
jq -n --argjson gi "$GI_ADDED" '{gitignore_added: $gi}' > "$DIR/init.json"

# 켠 레포 목록 (update-all 이 옛 설치본을 찾아 정리할 때 쓴다). 거절 목록에서는 뺀다.
if mkdir -p "$REG_DIR" 2>/dev/null; then
  { [ -f "$REG_DIR/installs" ] && cat "$REG_DIR/installs"; printf '%s\n' "$PROJECT"; } \
    | awk 'NF && !seen[$0]++' > "$REG_DIR/installs.tmp" && mv "$REG_DIR/installs.tmp" "$REG_DIR/installs"
  if [ -f "$REG_DIR/declined" ]; then
    grep -vxF "$PROJECT" "$REG_DIR/declined" > "$REG_DIR/declined.tmp"; mv "$REG_DIR/declined.tmp" "$REG_DIR/declined"
  fi
fi

if [ "$CREATED" = 1 ]; then
  say 'ai-bouncer를 켰다: %s\n  설정: %s (기본값과 다른 것만 적는다)\n' "$PROJECT" "$DIR/workflow.yaml"
else
  say 'ai-bouncer 설정 갱신: %s\n' "$PROJECT"
fi
if git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 \
   && [ -n "$(git -C "$PROJECT" status --porcelain -- .claude .gitignore CLAUDE.md 2>/dev/null)" ]; then
  say '  커밋하라 (안 하면 첫 작업이 finalize의 "워킹트리 정리 확인"에서 막힌다):\n'
  say '     git add .claude .gitignore CLAUDE.md && git commit -m "chore: ai-bouncer 설정"\n'
fi
exit 0
