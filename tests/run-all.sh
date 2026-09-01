#!/usr/bin/env bash
# 전체 테스트 실행
cd "$(dirname "${BASH_SOURCE[0]}")/.."
total_p=0; total_f=0; failed=""
for t in tests/cases/*.sh tests/e2e-install.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t" .sh)"
  printf '\n\033[1m── %s ──\033[0m\n' "$name"
  out="$(bash "$t" 2>&1)"; rc=$?
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
[ -z "$failed" ] && { printf '전부 통과 ✅\n'; exit 0; }
printf '실패한 테스트:%s\n' "$failed"; exit 1
