#!/usr/bin/env bash
# 케이스 22 — 업데이트 시 예전 기본값의 "검증 보고"(blocking: true)를 blocking: done 으로 옮긴다.
# 그리고 2026-10-22 정리: 검증 보고 자기신고·"목록 먼저 세우기" 지시를 예전 기본값에서만 뺀다.
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

# 2026-10-22: 검증 보고 자기신고(blocking: done)와 "목록을 먼저 세운다" 지시를 뺀다.
# 예전 기본값 그대로인 설치본만 바뀌고, 사용자가 넣은 다른 게이트는 남아야 한다.
cat > "$W/old.yaml" <<'YAML'
version: 1
workflows:
  simple:
    label: x
    stages: [implement, verify, done]
stages:
  implement:
    steps:
      - label: 구현 완료 대조
        blocking: checklist
        inject: |
          요청받은 항목을 **할 일 목록으로 먼저 세운다.** 자기보고가 아니라
          엔진이 항목 수를 세므로, 목록을 다 체크해야 다음 단계로 간다.

            bouncer todo add '항목1' '항목2' …    목록 세우기 (요청 범위 그대로)
            bouncer todo done <번호>              그 항목을 실제로 구현한 뒤 체크

          체크는 **실제로 그 코드를 넣은 뒤에** 한다. 사용자에게 확인을 묻지 말고 끝까지 진행한다.
    forbid:
      push: true
      reason: 검증 전에는 push할 수 없다.
  verify:
    steps:
      - label: 검증 보고
        # done: 검증을 마친 모델이 직접 표시한다. 사람 확인을 요구하면
        #       작업 도중 매번 사용자에게 승인을 묻게 된다 (done 전엔 물을 게 없다).
        blocking: done
        inject: |
          [verify] 검증 단계다.
      - label: 사람 확인
        blocking: done
        inject: 사용자가 직접 넣은 확인
  done:
    steps:
      - label: 완료
        inject: 끝
YAML
sed -n "/<<'PYP'/,/^PYP$/p" "$R/install.sh" | sed '1d;$d' > "$W/p.py"
python3 "$W/p.py" "$W/old.yaml" "$W/none.md" >/dev/null
grep -A1 'label: 검증 보고' "$W/old.yaml" | grep -q 'blocking' \
  && no "검증 보고 자기신고 남음" "$(grep -A3 '검증 보고' "$W/old.yaml")" || ok "검증 보고의 blocking: done 제거"
grep -q '먼저 세운다' "$W/old.yaml" && no "먼저 세운다 지시 남음" || ok "목록 먼저 세우기 지시 제거"
grep -q 'bouncer todo done <번호>`' "$W/old.yaml" && ok "체크 방법 안내는 남는다" || no "안내 소실"
grep -A1 'label: 사람 확인' "$W/old.yaml" | grep -q 'blocking: done' \
  && ok "사용자가 넣은 done 게이트는 그대로" || no "다른 게이트 변경됨"
grep -q 'push: true' "$W/old.yaml" && ok "forbid 는 그대로" || no "forbid 소실"
python3 "$R/engine/compile.py" "$W/old.yaml" "$W/old.json" >/dev/null 2>&1 \
  && ok "정리 결과가 컴파일된다" || no "컴파일 실패" "$(python3 "$R/engine/compile.py" "$W/old.yaml" "$W/old.json" 2>&1 | head -2)"
cp "$W/old.yaml" "$W/old2.yaml"; python3 "$W/p.py" "$W/old2.yaml" "$W/none.md" >/dev/null
cmp -s "$W/old.yaml" "$W/old2.yaml" && ok "두 번 돌려도 같다(멱등)" || no "멱등 아님"
finish
