#!/usr/bin/env bash
# 케이스 22 — 업데이트 시 예전 기본값의 "검증 보고"(blocking: true)를 blocking: done 으로 옮긴다.
# 사용자가 바꾼 다른 step 은 건드리지 않고, 결과는 그대로 컴파일돼야 한다.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

cat > "$W/wf.yaml" <<'YAML'
version: 1
workflows:
  simple:
    label: x
    stages: [verify, done]
stages:
  verify:
    steps:
      - label: 검증 보고
        blocking: true
        inject: 검증해라
      - label: 사람 확인
        blocking: true
        inject: 사용자가 직접 넣은 확인
  done:
    steps:
      - label: 완료
        inject: 끝
YAML

# install.sh 의 마이그레이션 블록을 그대로 꺼내 실행한다 (복붙하면 둘이 갈라진다).
sed -n "/<<'PYM'/,/^PYM$/p" "$R/install.sh" | sed '1d;$d' > "$W/m.py"
python3 "$W/m.py" "$W/wf.yaml" >/dev/null

grep -A1 'label: 검증 보고' "$W/wf.yaml" | grep -q 'blocking: done' \
  && ok "검증 보고 → blocking: done" || no "검증 보고 마이그레이션" "$(grep -A1 '검증 보고' "$W/wf.yaml")"
grep -A1 'label: 사람 확인' "$W/wf.yaml" | grep -q 'blocking: true' \
  && ok "사용자가 넣은 다른 step 은 그대로" || no "다른 step 변경됨"
python3 "$R/engine/compile.py" "$W/wf.yaml" "$W/wf.json" >/dev/null 2>&1 \
  && ok "마이그레이션 결과가 컴파일된다" || no "컴파일 실패"
cp "$W/wf.yaml" "$W/again.yaml"; python3 "$W/m.py" "$W/again.yaml" >/dev/null
cmp -s "$W/wf.yaml" "$W/again.yaml" && ok "두 번 돌려도 같다(멱등)" || no "멱등 아님"
finish
