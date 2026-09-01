#!/usr/bin/env bash
# 케이스 19 — 테스트 자체가 거짓말하지 않는지 본다.
#
# 감사에서 세 번 나온 패턴이다:
#  · 실패를 알린 뒤 무조건 ok 를 찍어 실패가 "통과 1건"으로 집계됨
#  · 에러 분기 `|| { … finish; exit; }` 안에 검증이 통째로 복붙돼 죽은 코드가 됨
#    (편집 스크립트가 `finish` 를 치환하면서 매번 되살아났다)
#  · 단정을 하나도 부르지 않는 자리표시 섹션
# run-all 은 ✅ 개수로 집계하므로 이런 건 스스로 초록불을 만든다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
CASES="$(dirname "${BASH_SOURCE[0]}")"

BAD=0
for f in "$CASES"/*.sh "$R"/tests/e2e-install.sh; do
  n="$(basename "$f")"
  [ "$n" = "19-test-hygiene.sh" ] && continue

  # 에러 분기 안에 검증이 들어가면 정상 경로에서 영원히 안 돈다
  if awk '/\|\| \{ no /{depth=1} depth && /finish; exit; \}/{print NR; exit}' "$f" | grep -q .; then
    start=$(grep -n '|| { no ' "$f" | head -1 | cut -d: -f1)
    end=$(grep -n 'finish; exit; }' "$f" | head -1 | cut -d: -f1)
    if [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$((start + 1))" ]; then
      no "$n 에러 분기가 여러 줄" "${start}~${end}행이 정상 경로에서 안 돈다 (붙여넣기 사고)"
      BAD=1
    fi
  fi

  # 연속된 여러 줄이 통째로 두 번 = 붙여넣기 사고.
  # (같은 ok 문구 하나가 두 번 나오는 건 재설치 검증처럼 의도적일 수 있다)
  if ! python3 - "$f" <<'PY'
import sys, pathlib
lines = [l.rstrip() for l in pathlib.Path(sys.argv[1]).read_text().split('\n')]
sig = [l for l in lines if l.strip() and not l.strip().startswith('#')]
N = 8
seen, dup = {}, None
for i in range(len(sig) - N + 1):
    key = '\n'.join(sig[i:i + N])
    if key in seen:
        dup = sig[i].strip()[:60]
        break
    seen[key] = i
if dup:
    print(dup)
    sys.exit(1)
PY
  then
    no "$n 에 통째로 복붙된 블록" "8줄 이상이 두 번 나온다"
    BAD=1
  fi
done
[ "$BAD" = 0 ] && ok "죽은 코드·중복 단정 없음"

# 단정을 하나도 안 부르는 섹션 (echo "[제목]" 뒤에 ok/no 가 없는 것)
BAD=0
for f in "$CASES"/*.sh; do
  n="$(basename "$f")"
  [ "$n" = "19-test-hygiene.sh" ] && continue
  empty="$(awk '
    /^echo "\[/ { if (title != "" && !seen) print title; title=$0; seen=0; next }
    /(^|[^a-z_])(ok|no) "/ { seen=1 }
    END { if (title != "" && !seen) print title }' "$f")"
  if [ -n "$empty" ]; then
    no "$n 에 단정 없는 섹션" "$(printf '%s' "$empty" | head -2 | tr '\n' ' ')"
    BAD=1
  fi
done
[ "$BAD" = 0 ] && ok "모든 섹션이 실제로 단정한다"

# (집계 일치는 run-all 이 전체를 돌리며 확인한다 — 여기서 또 돌리면 두 배로 느려진다)

finish
