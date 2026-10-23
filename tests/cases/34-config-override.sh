#!/usr/bin/env bash
# 케이스 34 — 기본값(엔진 소유) + 레포 override 병합, 옛 전체 사본 → override 마이그레이션, 폐기 키
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
CP="$R/engine/compile.py"
# 병합 대상 기본값은 엔진 옆 default.yaml, 없으면 ../config/default.yaml (소스 트리)
comp(){ python3 "$CP" "$1" "$W/out.json" >"$W/err" 2>&1; }
jqo(){ jq -r "$1" "$W/out.json"; }

echo "[병합 규칙]"
printf 'version: 1\n' > "$W/empty.yaml"
comp "$W/empty.yaml" && ok "override 가 비어도 기본값으로 컴파일" || no "빈 override" "$(head -2 "$W/err")"
BASE_STAGES="$(jqo '.workflows.plan.stages|join(",")')"
[ -n "$BASE_STAGES" ] && [ "$BASE_STAGES" != null ] && ok "기본 워크플로우 상속 ($BASE_STAGES)" || no "기본 워크플로우 상속"
: > "$W/zero.yaml"
comp "$W/zero.yaml" && ok "빈 파일도 통과" || no "빈 파일" "$(head -2 "$W/err")"
comp "$W/nonexistent.yaml" && ok "파일이 없어도 통과" || no "파일 없음" "$(head -2 "$W/err")"

cat > "$W/o1.yaml" <<'Y'
version: 1
settings:
  max_continue: 9
stages:
  verify:
    steps:
      - label: 린트
        run: "echo lint"
        blocking: true
Y
comp "$W/o1.yaml" && ok "새 label 은 추가된다" || no "추가" "$(head -2 "$W/err")"
[ "$(jqo '.settings.max_continue')" = 9 ] && ok "settings 키 단위 덮기" || no "settings 덮기"
[ "$(jqo '.settings.max_attempts')" != null ] && ok "덮지 않은 settings 는 기본값" || no "settings 기본값 유지"
[ "$(jqo '[.stages.verify.steps[]|select(.label=="린트")]|length')" = 1 ] && ok "추가 step 포함" || no "추가 step"
LAST="$(jqo '.stages.verify.steps[-1].label')"
[ "$LAST" = 린트 ] && ok "새 label 은 기본 step 뒤에 붙는다" || no "추가 위치" "$LAST"

# 기본 verify 의 첫 step label 을 교체해 본다
comp "$W/empty.yaml"; B_LABEL="$(jqo '.stages.verify.steps[0].label')"; B_N="$(jqo '.stages.verify.steps|length')"
cat > "$W/o2.yaml" <<Y
version: 1
stages:
  verify:
    steps:
      - label: $B_LABEL
        inject: "교체됨"
Y
comp "$W/o2.yaml" && ok "같은 label 교체 컴파일" || no "교체" "$(head -2 "$W/err")"
[ "$(jqo '.stages.verify.steps[0].label')" = "$B_LABEL" ] && [ "$(jqo '.stages.verify.steps[0].text')" = "교체됨" ] \
  && ok "같은 label 은 제자리 교체" || no "교체 위치/내용"
[ "$(jqo '.stages.verify.steps|length')" = "$B_N" ] && ok "교체는 step 수를 늘리지 않는다" || no "교체 수"

cat > "$W/o3.yaml" <<Y
version: 1
stages:
  verify:
    remove: ["$B_LABEL"]
Y
comp "$W/o3.yaml" && ok "remove 컴파일" || no "remove" "$(head -2 "$W/err")"
[ "$(jqo '.stages.verify.steps|length')" = "$((B_N-1))" ] && [ "$(jqo "[.stages.verify.steps[]|select(.label==\"$B_LABEL\")]|length")" = 0 ] \
  && ok "remove 는 기본 step 을 지운다" || no "remove 효과"

cat > "$W/o4.yaml" <<'Y'
version: 1
stages:
  plan:
    forbid:
      reason: 내 사유
Y
comp "$W/o4.yaml" && ok "forbid 일부만 덮기" || no "forbid" "$(head -2 "$W/err")"
[ "$(jqo '.stages.plan.forbid.reason')" = "내 사유" ] && [ "$(jqo '.stages.plan.forbid.push')" = true ] \
  && ok "forbid 는 키 단위 덮기 (push 유지)" || no "forbid 병합" "$(jqo '.stages.plan.forbid')"

cat > "$W/o5.yaml" <<'Y'
version: 1
bogus: 1
Y
comp "$W/o5.yaml" && no "override 의 모르는 루트 키" "통과됨" || ok "override 의 모르는 루트 키 거부"

cat > "$W/o6.yaml" <<'Y'
version: 1
base: none
workflows:
  w: {label: x, stages: [a]}
stages:
  a:
    steps: [{label: s, inject: "x"}]
Y
comp "$W/o6.yaml" && ok "base: none 은 기본값 없이 단독" || no "base none" "$(head -2 "$W/err")"
[ "$(jqo '.workflows|keys|join(",")')" = w ] && ok "base: none 에선 기본 워크플로우가 섞이지 않는다" || no "base none 오염" "$(jqo '.workflows|keys|join(",")')"

echo "[폐기·금지 키]"
cat > "$W/r1.yaml" <<'Y'
version: 1
stages:
  plan:
    forbid: {edit_files: true}
  verify:
    steps:
      - {label: 자기신고, inject: x, blocking: done}
      - {label: 승인류, inject: x, blocking: plan_approved}
Y
comp "$W/r1.yaml" && ok "폐기 키(edit_files, blocking: done/plan_approved)는 조용히 통과" || no "폐기 키" "$(head -2 "$W/err")"
[ "$(jqo '[.stages[].forbid|select(.!=null)|has("edit_files")]|any')" = false ] && ok "컴파일 결과에 edit_files 없음" || no "edit_files 잔존"
[ "$(jqo '[.stages.verify.steps[]|select(.label=="승인류")|.blocking]|all(.==null or .==false)')" = true ] \
  && ok "폐기된 blocking: plan_approved 는 비차단" || no "blocking 잔존" "$(jqo '[.stages.verify.steps[]|{label,blocking}]')"
[ "$(jqo '[.stages.verify.steps[]|select(.label=="자기신고")|.blocking][0]')" = true ] \
  && ok "blocking: done 은 true 와 같다" || no "done 이 꺼짐" "$(jqo '[.stages.verify.steps[]|{label,blocking}]')"
cat > "$W/r2.yaml" <<'Y'
version: 1
stages:
  verify:
    steps: [{label: s, inject: x, blocking: "skill:foo"}]
Y
comp "$W/r2.yaml" && no "blocking: skill:" "통과됨" || ok "blocking: skill:* 거부"
cat > "$W/r3.yaml" <<'Y'
version: 1
stages:
  verify:
    forbid: {bash: ["x"]}
Y
comp "$W/r3.yaml" && [ "$(jqo '.stages.verify.forbid|has("bash")')" = false ] \
  && ok "폐기된 forbid.bash 는 조용히 버린다" || no "forbid.bash" "$(head -2 "$W/err")"
[ "$(jq -r '[.stages[].forbid|select(.!=null)|has("bash")]|any' "$W/out.json" 2>/dev/null)" != true ] && ok "기본값 forbid 에 bash 없음" || no "bash 잔존"

echo "[마이그레이션]"
MIG="$R/engine/migrate-workflow.py"
mkdir -p "$W/m1"; cp "$R/config/default.yaml" "$W/m1/workflow.yaml"
python3 "$MIG" "$W/m1/workflow.yaml" >/dev/null 2>"$W/err" && ok "전체 사본 변환 실행" || no "변환 실행" "$(head -3 "$W/err")"
BODY="$(/usr/bin/grep -vE '^\s*(#|$)' "$W/m1/workflow.yaml")"
[ "$BODY" = "version: 1" ] && ok "기본값 그대로인 사본은 빈 override" || no "빈 override 아님" "$BODY"
[ -f "$W/m1/workflow.yaml.bak" ] && cmp -s "$W/m1/workflow.yaml.bak" "$R/config/default.yaml" && ok "원본은 workflow.yaml.bak 로 보존" || no ".bak"
cp "$W/m1/workflow.yaml" "$W/m1/before"; python3 "$MIG" "$W/m1/workflow.yaml" >/dev/null 2>&1
cmp -s "$W/m1/workflow.yaml" "$W/m1/before" && ok "두 번 돌려도 같다(멱등)" || no "멱등 아님"

mkdir -p "$W/m2"; cp "$R/config/default.yaml" "$W/m2/workflow.yaml"
python3 - "$W/m2/workflow.yaml" <<'P'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
s=s.replace('\nstages:\n','\nstages:\n  extra:\n    steps:\n      - label: 내 단계\n        inject: "x"\n',1) if False else s
s+='\n'
# settings 와 verify 에 사용자 step 을 넣는다
import re
s=re.sub(r'(\nsettings:\n)', r'\1  max_continue: 11\n', s, count=1) if '\nsettings:\n' in s else s.replace('version: 1\n','version: 1\nsettings:\n  max_continue: 11\n',1)
s=re.sub(r'(\n  verify:\n(?:    .*\n|\n)*?    steps:\n)', r'\1      - label: 내 린트\n        run: "echo mine"\n        blocking: true\n', s, count=1)
open(p,'w',encoding='utf-8').write(s)
P
python3 "$MIG" "$W/m2/workflow.yaml" >/dev/null 2>"$W/err" && ok "사용자 수정 사본 변환" || no "수정 사본 변환" "$(head -3 "$W/err")"
/usr/bin/grep -q '내 린트' "$W/m2/workflow.yaml" && ok "사용자가 추가한 step 은 남는다" || no "사용자 step 소실"
/usr/bin/grep -q 'max_continue: 11' "$W/m2/workflow.yaml" && ok "기본값과 다른 settings 는 남는다" || no "settings 소실"
[ "$(/usr/bin/grep -c 'label:' "$W/m2/workflow.yaml")" = 1 ] && ok "기본값과 같은 step 은 버려진다" || no "중복 step 잔존" "$(/usr/bin/grep -c 'label:' "$W/m2/workflow.yaml")개"
comp "$W/m2/workflow.yaml" && [ "$(jqo '.settings.max_continue')" = 11 ] \
  && [ "$(jqo '[.stages.verify.steps[]|select(.label=="내 린트")]|length')" = 1 ] \
  && ok "변환 결과가 컴파일돼 의도가 유지된다" || no "변환 결과" "$(head -2 "$W/err")"

# 폐기 키·옛 plan.md 프롬프트 정리
mkdir -p "$W/m3/prompts"; cp "$R/config/default.yaml" "$W/m3/workflow.yaml"
python3 - "$W/m3/workflow.yaml" <<'P'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
s=s.replace('      push: true\n','      push: true\n      edit_files: true\n',1)
open(p,'w',encoding='utf-8').write(s)
P
printf '아무 말이나 적힌 사용자 프롬프트\n' > "$W/m3/prompts/mine.md"
python3 "$MIG" "$W/m3/workflow.yaml" >/dev/null 2>&1
/usr/bin/grep -q 'edit_files' "$W/m3/workflow.yaml" && no "폐기 키 제거" "남음" || ok "폐기된 forbid.edit_files 는 변환 때 제거"
[ -f "$W/m3/prompts/mine.md" ] && ok "알 수 없는 사용자 프롬프트는 보존" || no "사용자 프롬프트 삭제됨"

# 옛 버전의 default.yaml (git 이력이 있을 때만)
OLD="$(git -C "$R" log --format=%h -- config/default.yaml 2>/dev/null | tail -1)"
if [ -n "$OLD" ] && git -C "$R" show "$OLD:config/default.yaml" > "$W/old-default.yaml" 2>/dev/null; then
  mkdir -p "$W/m4"; cp "$W/old-default.yaml" "$W/m4/workflow.yaml"
  python3 "$MIG" "$W/m4/workflow.yaml" >/dev/null 2>"$W/err" && comp "$W/m4/workflow.yaml" \
    && ok "가장 오래된 기본값 사본($OLD)도 변환·컴파일된다" || no "옛 사본 변환" "$(head -3 "$W/err")"
  echo "[지문 커버리지]"
  MISSING=0
  for c in $(git -C "$R" log --format=%h -- config/default.yaml 2>/dev/null); do
    git -C "$R" show "$c:config/default.yaml" > "$W/h.yaml" 2>/dev/null || continue
    cmp -s "$W/h.yaml" "$R/config/default.yaml" && continue          # 현재 기본값은 default.yaml 로 비교된다
    mkdir -p "$W/h"; cp "$W/h.yaml" "$W/h/workflow.yaml"
    python3 "$MIG" "$W/h/workflow.yaml" >/dev/null 2>&1
    B="$(/usr/bin/grep -vE '^\s*(#|$)' "$W/h/workflow.yaml")"
    [ "$B" = "version: 1" ] || { MISSING=$((MISSING+1)); printf '     ↳ %s 는 빈 override 가 안 된다\n' "$c"; }
    rm -rf "$W/h"
  done
  [ "$MISSING" = 0 ] && ok "과거 모든 기본값 버전이 빈 override 로 변환 (config/legacy-defaults.json)" \
    || no "legacy-defaults.json 갱신 필요" "python3 tools/gen-legacy-defaults.py"
fi

echo "[설치·업데이트]"
unset CLAUDE_CONFIG_DIR
if [ -z "${BOUNCER_TEST_HOME:-}" ]; then BOUNCER_TEST_HOME="$(mktemp -d)"; export BOUNCER_TEST_HOME HOME="$BOUNCER_TEST_HOME"; fi
P1="$(mktemp -d)"
( cd "$P1" && git init -q . && git config user.email t@t && git config user.name t && echo a > a && git add a && git commit -qm i
  mkdir -p .claude/ai-bouncer; cp "$R/config/default.yaml" .claude/ai-bouncer/workflow.yaml
  cat > .claude/settings.json <<'J'
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/ai-bouncer/hooks/user-prompt.sh" } ] } ] } }
J
  bash "$R/install.sh" --ci >/dev/null 2>&1 ) || no "설치 실행"
A="$P1/.claude/ai-bouncer"
GE="$HOME/.claude/ai-bouncer/engine"
[ -f "$GE/default.yaml" ] && cmp -s "$GE/default.yaml" "$R/config/default.yaml" && ok "기본값은 전역 엔진 쪽 default.yaml 로 설치" || no "default.yaml 설치"
B="$(/usr/bin/grep -vE '^\s*(#|$)' "$A/workflow.yaml")"
[ "$B" = "version: 1" ] && ok "업데이트 시 옛 전체 사본이 빈 override 로 바뀐다" || no "설치 시 변환" "$B"
[ -f "$A/workflow.yaml.bak" ] && ok "업데이트가 .bak 을 남긴다" || no ".bak 없음"
/usr/bin/grep -q 'user-prompt' "$P1/.claude/settings.json" && no "UserPromptSubmit 잔재" "남음" || ok "옛 user-prompt hook 등록은 업데이트 때 제거"
# ai-bouncer hook 만 있던 프로젝트 settings 는 비어서 지워진다 (hook 은 이제 전역 settings 에 있다)
{ [ ! -f "$P1/.claude/settings.json" ] || jq -e '(.hooks.UserPromptSubmit // []) == []' "$P1/.claude/settings.json" >/dev/null; } && ok "UserPromptSubmit 등록 없음" || no "UserPromptSubmit 등록됨"
[ -f "$A/workflow.compiled.json" ] && ok "컴파일본 생성" || no "컴파일본 없음"
echo "# 내 메모" >> "$A/workflow.yaml"
( cd "$P1" && bash "$R/install.sh" --ci >/dev/null 2>&1 )
/usr/bin/grep -q '내 메모' "$A/workflow.yaml" && ok "재설치는 override 를 건드리지 않는다" || no "override 덮어씀"
echo "변조" >> "$GE/default.yaml"
( cd "$P1" && bash "$R/install.sh" --ci >/dev/null 2>&1 )
cmp -s "$GE/default.yaml" "$R/config/default.yaml" && ok "엔진 default.yaml 은 업데이트마다 덮어쓴다" || no "default.yaml 보존됨"
rm -rf "$P1"
finish
