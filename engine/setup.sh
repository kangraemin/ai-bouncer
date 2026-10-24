#!/usr/bin/env bash
# bouncer setup — 이 레포의 workflow.yaml 을 사용자와 대화로 정하라는 안내를 낸다 (아무것도 쓰지 않는다).
# 레포에서 검사 명령을 찾아 추천 근거로 함께 보여 준다. 모델이 이 안내대로 묻고, 답을 받아 yaml 을 쓴다.

set -uo pipefail
_D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_D/lib/common.sh"

ROOT="$(cd "$(bouncer_project_root "$PWD")" && pwd -P)"
YAML="$(bouncer_workflow_yaml "$PWD")"
[ -f "$YAML" ] || { printf 'ai-bouncer: 이 레포에는 아직 설정이 없다 — 먼저 bouncer init\n' >&2; exit 1; }

# 안내를 냈으면 예약은 끝난 것이다. 세션 시작 때 다시 띄우지 않는다.
REG="$(bouncer_registry_dir)/setup-pending"
if [ -f "$REG" ]; then grep -vxF "$ROOT" "$REG" > "$REG.tmp"; mv "$REG.tmp" "$REG"; fi

# ── 레포에서 검사 명령 찾기 ──────────────────────────────────
found=()
add() { found+=("$1	$2	$3"); }   # id, 명령, 근거
cd "$ROOT" || exit 1
if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
  pm="npm run"
  [ -f pnpm-lock.yaml ] && pm="pnpm"; [ -f yarn.lock ] && pm="yarn"; { [ -f bun.lockb ] || [ -f bun.lock ]; } && pm="bun run"
  for k in test lint typecheck type-check build e2e test:e2e; do
    jq -e --arg k "$k" '.scripts[$k]' package.json >/dev/null 2>&1 || continue
    id="${k//:/-}"; [ "$id" = type-check ] && id=typecheck; [ "$id" = test-e2e ] && id=e2e
    add "$id" "$pm $k" "package.json scripts.$k"
  done
fi
if [ -f Makefile ]; then
  for k in test lint check build; do
    grep -Eq "^$k:" Makefile && add "$k" "make $k" "Makefile"
  done
fi
if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ] || ls tests/test_*.py >/dev/null 2>&1; then
  { grep -qs pytest pyproject.toml pytest.ini setup.cfg requirements*.txt || ls tests/test_*.py >/dev/null 2>&1; } \
    && add test "pytest" "pytest 설정/tests"
  grep -qs ruff pyproject.toml && add lint "ruff check ." "pyproject.toml ruff"
fi
[ -f go.mod ]      && { add test "go test ./..." "go.mod"; add lint "go vet ./..." "go.mod"; }
[ -f Cargo.toml ]  && { add test "cargo test" "Cargo.toml"; add lint "cargo clippy -- -D warnings" "Cargo.toml"; }
[ -x gradlew ]     && add test "./gradlew test" "gradlew"
[ -f tests/run-all.sh ] && add test "bash tests/run-all.sh" "tests/run-all.sh"

HAS_STAGES=0; grep -Eq '^(workflows|stages):' "$YAML" && HAS_STAGES=1

cat <<EOF
[ai-bouncer setup] 이 레포($ROOT)의 워크플로우를 사용자와 대화로 정한다.
설정 파일: $YAML
EOF
[ "$HAS_STAGES" = 1 ] && printf '이미 단계 설정이 있다. 먼저 현재 내용을 보여 주고 바꿀 부분만 묻는다.\n'
printf '\n레포에서 찾은 검사 명령:\n'
if [ ${#found[@]} -eq 0 ]; then
  printf '  (찾지 못했다 — 무엇으로 테스트·린트·빌드하는지 사용자에게 묻는다)\n'
else
  printf '%s\n' "${found[@]}" | awk -F'\t' '!seen[$2]++ {printf "  - %-10s %-28s (근거: %s)\n", $1, $2, $3}'
fi
cat <<'EOF'

진행 순서
1. AskUserQuestion 한 번에 아래를 묻는다. 각 질문의 첫 선택지가 추천안이고, 라벨 끝에 "(Recommended)"를 붙인다.
   추천에는 왜 그런지 레포 근거를 한 줄 붙인다.
   ① 모드 구성
      - plan + simple (Recommended) — 큰 작업은 계획부터, 작은 작업은 바로
      - simple 만 — 계획 단계 없이
      - plan + simple + quick — quick 은 검증 항목을 AI 가 고른다
      - 기본값 그대로 — 고르면 `bouncer init --defaults` 하고 끝낸다
   ② 검증 항목 (multiSelect) — 위에서 찾은 명령을 항목으로 낸다. 1분 넘게 걸릴 것(e2e 등)은 그렇다고 적는다.
   ③ 검증 항목을 고르는 방식
      - ask (Recommended) — 작업을 시작할 때마다 사용자에게 묻는다
      - auto — AI 가 작업 내용을 보고 고른다
      - all — 매번 전부 한다
   ④ 마무리
      - 커밋하고 push (Recommended) / 커밋만 / 마무리 단계 없음
2. 답이 애매하거나 사용자가 덧붙이면 이어서 묻는다. 정할 것이 다 정해질 때까지 주고받는다.
3. 정해지면 설정 파일을 쓴다. 엔진 기본값과 다른 것만 적는다.
   - 적지 않은 단계·prompt 는 엔진 기본값이 들어간다(기본 단계: plan, implement, verify, finalize).
   - 검사 명령은 stages.verify.items.<id>.run 에 둔다. 기본 항목 test·review 는 지울 수 없다.
     test 는 run 을 덮어쓰고, review 가 필요 없으면 ask/auto 로 두어 고르지 않으면 된다.
   - 1분 넘게 걸리는 검사는 run 에 직접 넣지 않는다. prompt 로 모델이 돌려 결과 파일을 남기게 하고,
     run 은 `bouncer fresh <결과파일> && <통과 확인>` 으로 결과만 본다.
   - "커밋만"이면 stages.finalize.prompt 를 바꾸고, "마무리 없음"이면 모드의 stages 에서 finalize 를 뺀다.

   예:
     workflows:
       plan:   {label: 계획을 세우고 승인받은 뒤 구현, stages: [plan, implement, verify, finalize]}
       simple: {label: 계획 없이 바로 구현, stages: [implement, verify, finalize]}
     stages:
       verify:
         choosable: ask
         items:
           test: {label: 유닛 테스트 (npm test), run: npm test}
           lint: {label: 린트 (npm run lint), run: npm run lint}
4. `bouncer check` 가 OK 인지 확인한다. 쓴 내용을 사용자에게 보여 주고, 커밋해야 한다고 알린다.

AskUserQuestion 을 쓸 수 없는 세션이면 묻지 말고 `bouncer init --defaults` 로 기본값을 쓴다.
EOF
