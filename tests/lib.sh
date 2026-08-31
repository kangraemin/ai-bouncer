# 케이스 e2e 공용 헬퍼
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
finish(){ printf '\n  %d 통과 / %d 실패\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

# setup <workflow.yaml 경로> [프롬프트디렉토리]
setup() {
  T="$(mktemp -d)"; cd "$T"
  git init -q .; git config user.email t@t; git config user.name t
  echo hello > app.js; git add app.js; git commit -qm init
  printf '.ai-bouncer/\n' > .gitignore
  mkdir -p .claude/ai-bouncer/prompts
  cp "$1" .claude/ai-bouncer/workflow.yaml
  [ -n "${2:-}" ] && cp "$2"/*.md .claude/ai-bouncer/prompts/ 2>/dev/null
  printf '{"max_continue":3,"max_attempts":2}\n' > .claude/ai-bouncer/config.json
  printf 'workflow.compiled.json\n' > .claude/ai-bouncer/.gitignore
  python3 "$R/engine/compile.py" .claude/ai-bouncer/workflow.yaml \
          .claude/ai-bouncer/workflow.compiled.json >/dev/null || return 1
  git add .gitignore .claude && git commit -qm cfg
}
cleanup(){ cd /; rm -rf "$T"; }

bouncer(){ bash "$R/engine/bouncer.sh" "$@"; }
# 실패로 끝나는 명령의 출력을 검사할 때 쓴다 (pipefail 때문에 파이프로 못 씀)
says(){ local pat="$1"; shift; local o; o="$("$@" 2>&1 || true)"; printf '%s' "$o" | grep -q "$pat"; }
hook(){ local h="$1"; shift; printf '%s' "$1" | bash "$R/hooks/$h.sh"; }
stop(){ hook stop "{\"session_id\":\"${1:-S1}\",\"cwd\":\"$T\"}"; }
pre(){ hook pre-tool "{\"session_id\":\"${3:-S1}\",\"cwd\":\"$T\",\"tool_name\":\"$1\",\"tool_input\":$2}"; }
state(){ jq -r "$1" "$T"/.ai-bouncer/tasks/*/state.json 2>/dev/null; }
stage(){ state .current_stage; }
