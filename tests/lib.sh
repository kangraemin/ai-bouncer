# 케이스 e2e 공용 헬퍼
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
finish(){ printf '\n  %d 통과 / %d 실패\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

# 목록을 한 범주로 묶어 검사한다. 통과하면 한 줄, 실패한 항목만 개별로 나온다.
# 항목마다 ok 를 부르면 통과 시 출력이 수십 줄이 되어 아무도 안 읽는다.
# 사용법:  group "범주 이름" 판정함수 <<'X'
#          항목1
#          항목2
#          X
# 판정함수는 항목을 받아 "기대대로면 0" 을 반환해야 한다.
# 주의: 파이프로 호출하면 서브셸이라 PASS/FAIL 이 유실된다.
# `group <이름> <판정함수> <<'X' ... X` 처럼 히어독으로 넘겨야 한다.
group(){
  local name="$1" fn="$2" total=0 bad=0 item
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    total=$((total+1))
    if ! "$fn" "$item"; then bad=$((bad+1)); printf '     ↳ %s\n' "$item"; fi
  done
  if [ "$bad" -eq 0 ]; then
    printf '  ✅ %s (%d건)\n' "$name" "$total"; PASS=$((PASS+1))
  else
    printf '  ❌ %s — %d/%d 실패\n' "$name" "$bad" "$total"; FAIL=$((FAIL+1))
  fi
}

# setup <workflow.yaml 경로> [프롬프트디렉토리]
setup() {
  T="$(mktemp -d)"; cd "$T"
  git init -q .; git config user.email t@t; git config user.name t
  echo hello > app.js; git add app.js; git commit -qm init
  printf '.ai-bouncer/\n' > .gitignore
  mkdir -p .claude/ai-bouncer/prompts
  cp "$1" .claude/ai-bouncer/workflow.yaml
  [ -n "${2:-}" ] && cp "$2"/*.md .claude/ai-bouncer/prompts/ 2>/dev/null
  # 설정은 yaml의 settings 섹션에 넣는다 (별도 config 파일 없음)
  python3 "$R/tests/set-settings.py" .claude/ai-bouncer/workflow.yaml max_continue=3 max_attempts=2
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
# 사용자가 실제로 입력한 상황을 흉내낸다. inject+blocking 게이트는 이게 있어야 통과한다.
user_turn(){ hook user-prompt "{\"session_id\":\"${1:-S1}\",\"cwd\":\"$T\"}"; }
pre(){ hook pre-tool "{\"session_id\":\"${3:-S1}\",\"cwd\":\"$T\",\"tool_name\":\"$1\",\"tool_input\":$2}"; }
# 가장 최근 작업 하나만 본다. 글롭으로 전부 읽으면 케이스가 쌓일수록
# 값이 여러 줄로 섞여 나와 비교가 조용히 무너진다.
task_dir(){ ls -dt "$T"/.ai-bouncer/tasks/*/ 2>/dev/null | head -1; }
state(){ local d; d="$(task_dir)"; [ -n "$d" ] || return 1; jq -r "$1" "$d/state.json" 2>/dev/null; }
stage(){ state .current_stage; }
