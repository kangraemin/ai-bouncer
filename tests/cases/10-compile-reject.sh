#!/usr/bin/env bash
# 케이스 10 — 잘못된 config는 컴파일 단계에서 거부된다 (실행 중 마비 방지)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
try() { local name="$1"; shift; cat > "$T/c.yaml"; 
  if python3 "$R/engine/compile.py" "$T/c.yaml" "$@" >/dev/null 2>&1; then no "$name" "통과됨"; else ok "$name"; fi; }

try "체인에 정의 없는 스테이지" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a, verfiy, z]}}
stages: {a: {steps: [{label: s, inject: "x"}]}, verify: {steps: [{label: s, inject: "x"}]}, z: {steps: [{label: s, inject: "x"}]}}
Y
try "on_fail이 뒤쪽 스테이지" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a, z]}}
stages: {a: {on_fail: z, steps: [{label: s, inject: "x"}]}, z: {steps: [{label: s, inject: "x"}]}}
Y
try "blocking인데 label 없음" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{run: "x", blocking: true}]}}
Y
try "blocking 값이 목록 밖" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, run: "x", blocking: maybe}]}}
Y
try "run에 plan_approved" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, run: "x", blocking: plan_approved}]}}
Y
try "by: engine + timeout 600" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, run: "x", by: engine, timeout: 600, blocking: true}]}}
Y
try "forbid에 reason 없음" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, inject: "x"}], forbid: {push: true}}}
Y
try "inject_file 경로 없음" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, inject_file: nope.md}]}}
Y
try "고아 스테이지" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, inject: "x"}]}, ghost: {steps: [{label: g, inject: "x"}]}}
Y
try "inject와 run 동시" <<'Y'
version: 1
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, inject: "x", run: "y"}]}}
Y
try "workflow에 label 없음" <<'Y'
version: 1
workflows: {p: {stages: [a]}}
stages: {a: {steps: [{label: s, inject: "x"}]}}
Y
try "내장 파서 + YAML 앵커" --builtin-parser <<'Y'
version: 1
common: &x
  push: true
workflows: {p: {label: x, stages: [a]}}
stages: {a: {steps: [{label: s, inject: "x"}]}}
Y
finish
