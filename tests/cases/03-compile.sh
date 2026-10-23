#!/usr/bin/env bash
# 케이스 03 — 컴파일: 기본값 병합 규칙, 거부, 두 파서 일치
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
if [ -z "${BOUNCER_TEST_HOME:-}" ]; then
  BOUNCER_TEST_HOME="$(mktemp -d)"; export BOUNCER_TEST_HOME HOME="$BOUNCER_TEST_HOME"
fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
C(){ python3 "$R/engine/compile.py" "$T/w.yaml" "$@"; }
w(){ cat > "$T/w.yaml"; }

# ── 병합 ──
printf '# 비어 있음\n' | w
O="$(C)" && [ "$(jq -r '.workflows|keys|join(",")' <<<"$O")" = "plan,simple" ] && ok "빈 레포 설정 = 기본값 그대로" || no "빈 설정"
[ "$(jq -r '.stages.verify.choosable' <<<"$O")" = ask ] && ok "기본 verify 는 ask" || no "기본 verify"
[ "$(jq -r '.workflows.plan.choosable.verify' <<<"$O")" = ask ] && ok "모드에 단계 방식이 풀려 들어간다" || no "모드 방식"

w <<'Y'
workflows:
  mine: {stages: [implement, verify]}
Y
O="$(C)"; [ "$(jq -r '.workflows|keys|join(",")' <<<"$O")" = mine ] && ok "workflows 를 적으면 모드 목록을 통째로 대신한다" || no "모드 대체" "$O"

w <<'Y'
stages:
  verify:
    run: npm test
    items:
      test: {label: 바꾼 테스트, run: make test}
      extra: {label: 추가, prompt: 더}
Y
O="$(C)"
[ "$(jq -r '.stages.verify.run|join(",")' <<<"$O")" = "npm test" ] && ok "단계 안에서 키 단위로 덮어쓴다" || no "키 덮어쓰기"
jq -e '.stages.verify.prompt | contains("검증 단계다")' <<<"$O" >/dev/null && ok "안 적은 키(prompt)는 기본값 유지" || no "prompt 유지"
[ "$(jq -r '.stages.verify.items|map(.id)|join(",")' <<<"$O")" = "test,review,extra" ] && ok "items 는 id 단위로 교체·추가" || no "items 병합" "$(jq -c .stages.verify.items <<<"$O")"
[ "$(jq -r '.stages.verify.items[0].label' <<<"$O")" = "바꾼 테스트" ] && ok "같은 id 는 교체" || no "id 교체"

w <<'Y'
stages:
  plan: {prompt: 내 계획 지시}
Y
O="$(C)"; [ "$(jq -r '.stages.plan.prompt' <<<"$O")" = "내 계획 지시" ] && ok "prompt 를 적으면 기본 prompt_file 을 대신한다" || no "prompt 쌍 교체" "$(jq -r .stages.plan.prompt <<<"$O")"

w <<'Y'
workflows:
  s:  {stages: [implement, verify]}
  ss: {stages: [implement, verify], choosable: {verify: auto}}
Y
O="$(C)"; [ "$(jq -r '[.workflows.s.choosable.verify, .workflows.ss.choosable.verify]|join(",")' <<<"$O")" = "ask,auto" ] \
  && ok "모드별 choosable 덮어쓰기" || no "모드별 방식"
w <<'Y'
version: 1
stages:
  implement: {run: "true"}
Y
C >/dev/null 2>&1 && ok "version 키는 허용한다" || no "version"

# ── 거부 ──
rej(){ local name="$1" pat="$2" e; e="$(w; C 2>&1 >/dev/null)" && { no "$name" "통과됨"; return; }
  printf '%s' "$e" | grep -q -- "$pat" && ok "$name" || no "$name" "$e"; }
rej "모르는 최상위 키 + 옛 형식 안내" "bouncer init" <<'Y'
base: none
Y
rej "모르는 단계 키" "알 수 없는 키: steps" <<'Y'
stages:
  implement: {steps: []}
Y
rej "choosable 값 검사" "ask / auto / all" <<'Y'
stages:
  verify: {choosable: true}
Y
rej "모드 choosable 은 그 모드 단계만" "이 모드의 단계가 아니다" <<'Y'
workflows:
  s: {stages: [implement], choosable: {verify: auto}}
Y
rej "모드 choosable 값 검사" "ask / auto / all" <<'Y'
workflows:
  s: {stages: [implement], choosable: {implement: maybe}}
Y
rej "정의 안 된 단계" "정의되지 않은 단계" <<'Y'
workflows:
  s: {stages: [implement, nope]}
Y
rej "중복 단계" "중복" <<'Y'
workflows:
  s: {stages: [implement, implement]}
Y
rej "빈 체인" "비어 있지 않은" <<'Y'
workflows:
  s: {stages: []}
Y
rej "item id 형식" "id 는" <<'Y'
stages:
  verify:
    items:
      "a b": {label: x}
Y
rej "없는 prompt_file" "prompt_file" <<'Y'
stages:
  implement: {prompt_file: prompts/none.md}
Y

# ── 두 파서 결과가 같다 (pyyaml 이 없는 머신에서 조용히 달라지면 안 된다) ──
for f in "$R"/config/default.yaml "$R"/examples/*.yaml "$R"/tests/fixtures/*.yaml; do
  n=$(basename "$f")
  python3 "$R/engine/compile.py" "$f" "$T/a.json" >/dev/null 2>&1 || { no "$n pyyaml"; continue; }
  python3 "$R/engine/compile.py" "$f" "$T/b.json" --builtin-parser >/dev/null 2>&1 || { no "$n 내장"; continue; }
  diff -q <(jq -S 'del(.compiled_at,.parser)' "$T/a.json") <(jq -S 'del(.compiled_at,.parser)' "$T/b.json") >/dev/null \
    && ok "$n 두 파서 결과 일치" || no "$n 파서 불일치"
done
printf 'stages:\n  implement: {prompt: "bad \\q"}\n' > "$T/w.yaml"
for parser in "" "--builtin-parser"; do
  # shellcheck disable=SC2086
  C "$T/x.json" $parser >/dev/null 2>&1 && no "잘못된 이스케이프 거부 (${parser:-pyyaml})" "통과됨" || ok "잘못된 이스케이프 거부 (${parser:-pyyaml})"
done

finish
