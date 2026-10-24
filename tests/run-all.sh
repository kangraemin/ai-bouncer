#!/usr/bin/env bash
# 전체 테스트 실행. 인자로 케이스 파일을 주면 그것만 돈다.
# 끝나면 .ai-bouncer/test-result 에 `fail: N` 을 남긴다 — 이 레포의 verify run 이 `bouncer fresh` 로 이 리포트를 확인한다.
# (결과 파일을 스스로 남기는 테스트라 `bouncer record` 대신 이 방식을 쓴다)
ARGS=()
for a in "$@"; do ARGS+=("$(cd "$(dirname "$a")" 2>/dev/null && pwd)/$(basename "$a")"); done
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# 테스트는 실제 홈을 건드리면 안 된다. 설치 e2e 는 $HOME/.claude 와 $HOME/.local/bin 에 쓴다.
unset CLAUDE_CONFIG_DIR XDG_STATE_HOME BOUNCER_REGISTRY_DIR
if [ -z "${BOUNCER_TEST_HOME:-}" ]; then
  BOUNCER_TEST_HOME="$(mktemp -d)"
  export BOUNCER_TEST_HOME HOME="$BOUNCER_TEST_HOME"
  OWN_HOME=1
fi

# 케이스끼리는 독립이라 병렬로 돈다 (순차로 10분 넘게 걸렸다).
# 케이스마다 HOME 을 따로 줘서 설치 목록·런처가 서로 섞이지 않게 한다.
# 출력은 다 끝난 뒤 원래 순서대로 찍는다. 동시 실행 수는 BOUNCER_TEST_FILE_JOBS(기본 6).
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"; [ -n "${OWN_HOME:-}" ] && rm -rf "$BOUNCER_TEST_HOME"' EXIT
FILE_JOBS="${BOUNCER_TEST_FILE_JOBS:-6}"
ALL=""
if [ "${#ARGS[@]}" -gt 0 ]; then
  for t in "${ARGS[@]}"; do [ -f "$t" ] || { echo "테스트 파일 없음: $t" >&2; exit 1; }; ALL="$ALL $t"; done
else
  for t in tests/cases/*.sh tests/e2e-install.sh tests/e2e-update-all.sh; do [ -f "$t" ] && ALL="$ALL $t"; done
fi
# 큰 케이스부터 띄운다 — 긴 것이 마지막에 혼자 돌면 병렬 효과가 사라진다.
for t in $(ls -S $ALL); do
  while [ "$(jobs -rp | wc -l)" -ge "$FILE_JOBS" ]; do sleep 0.2; done
  name="$(basename "$t" .sh)"
  (
    h="$(mktemp -d "$BOUNCER_TEST_HOME/h.XXXXXX")"
    s=$(date +%s)
    HOME="$h" BOUNCER_TEST_HOME="$h" bash "$t" > "$OUT/$name.out" 2>&1
    echo $? > "$OUT/$name.rc"; echo $(( $(date +%s) - s )) > "$OUT/$name.sec"
  ) &
done
wait

total_p=0; total_f=0; failed=""
for t in $ALL; do
  name="$(basename "$t" .sh)"
  printf '\n\033[1m── %s ──\033[0m (%ss)\n' "$name" "$(cat "$OUT/$name.sec" 2>/dev/null)"
  out="$(cat "$OUT/$name.out" 2>/dev/null)"; rc="$(cat "$OUT/$name.rc" 2>/dev/null || echo 1)"
  printf '%s\n' "$out"
  # 케이스가 스스로 보고한 수를 쓴다. ✅ 개수로 세면 엔진 출력
  # (`✅ [implement] 완료 → …`)까지 통과로 집계돼 총계가 흔들린다.
  summary="$(printf '%s' "$out" | sed -n 's/^[^0-9]*\([0-9][0-9]*\) 통과 \/ \([0-9][0-9]*\) 실패$/\1 \2/p' | tail -1)"
  if [ -n "$summary" ]; then
    p="${summary%% *}"; f="${summary##* }"
  else
    p=0; f=1; failed="$failed $name(요약없음)"
  fi
  total_p=$((total_p+p)); total_f=$((total_f+f))
  [ "$rc" -eq 0 ] || failed="$failed $name"
done
printf '\n════════════════════════════\n총 %d 통과 / %d 실패\n' "$total_p" "$total_f"
# 전체를 돌렸을 때만 리포트를 남긴다 — 일부만 돌린 결과로 verify 를 통과하면 안 된다.
if [ "${#ARGS[@]}" -eq 0 ]; then
  mkdir -p .ai-bouncer && printf 'fail: %d\npass: %d\n' "$([ -z "$failed" ] && echo "$total_f" || echo $((total_f>0?total_f:1)))" "$total_p" > .ai-bouncer/test-result
fi
[ -z "$failed" ] && { printf '전부 통과 ✅\n'; exit 0; }
printf '실패한 테스트:%s\n' "$failed"; exit 1
