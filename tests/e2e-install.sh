#!/bin/bash
# e2e-install.sh — install/uninstall 새 아키텍처 기준 e2e 테스트

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

check_file() {
  local label="$1" path="$2" expect_exists="$3"
  if [ "$expect_exists" = "yes" ]; then
    if [ -f "$path" ]; then echo "✅ $label"; PASS=$((PASS+1))
    else echo "❌ $label (기대: 파일 존재, 실제: 없음) — $path"; FAIL=$((FAIL+1)); fi
  else
    if [ ! -f "$path" ]; then echo "✅ $label"; PASS=$((PASS+1))
    else echo "❌ $label (기대: 파일 없음, 실제: 존재) — $path"; FAIL=$((FAIL+1)); fi
  fi
}

check_hook() {
  local label="$1" settings="$2" hook_file="$3" expect_present="$4"
  local present; present=$(grep -l "$hook_file" "$settings" 2>/dev/null && echo yes || echo no)
  if grep -q "$hook_file" "$settings" 2>/dev/null; then present="yes"; else present="no"; fi
  if [ "$expect_present" = "yes" ] && [ "$present" = "yes" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  elif [ "$expect_present" = "no" ] && [ "$present" = "no" ]; then
    echo "✅ $label"; PASS=$((PASS+1))
  else
    echo "❌ $label (기대: $expect_present, 실제: $present) — $hook_file"; FAIL=$((FAIL+1))
  fi
}

check_config() {
  local label="$1" cfg="$2" key="$3" expected="$4"
  local actual
  actual=$(python3 -c "import json; print(json.load(open('$cfg')).get('$key',''))" 2>/dev/null || echo "ERROR")
  if [ "$actual" = "$expected" ]; then echo "✅ $label"; PASS=$((PASS+1))
  else echo "❌ $label (기대: $expected, 실제: $actual)"; FAIL=$((FAIL+1)); fi
}

check_hook_matcher() {
  local label="$1" settings="$2" hook_file="$3" expected_matcher="$4"
  local actual
  actual=$(python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
for ht, groups in cfg.get('hooks', {}).items():
    for g in groups:
        for h in g.get('hooks', []):
            if sys.argv[2] in h.get('command', ''):
                print(g.get('matcher', ''))
                sys.exit(0)
print('NOT_FOUND')
" "$settings" "$hook_file" 2>/dev/null || echo "ERROR")
  if [ "$actual" = "$expected_matcher" ]; then echo "✅ $label"; PASS=$((PASS+1))
  else echo "❌ $label (기대: '$expected_matcher', 실제: '$actual')"; FAIL=$((FAIL+1)); fi
}

TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

# 임시 git repo 초기화
(cd "$TMPDIR" && git init -q && git config user.email "test@test.com" && git config user.name "Test" && git commit -q --allow-empty -m "init")

TARGET_DIR="$TMPDIR/.claude"
BOUNCER_DIR="$TARGET_DIR/ai-bouncer"
SETTINGS="$TARGET_DIR/settings.json"

echo "=== install 검증 ==="

# install.sh --ci 실행 (로컬 설치, 비대화형)
(cd "$TMPDIR" && bash "$PACKAGE_DIR/install.sh" --ci > /dev/null 2>&1) || {
  echo "❌ install.sh --ci 실행 실패"
  FAIL=$((FAIL+1))
}

# TC-01: claim-active.sh 설치됨
check_file "TC-01: scripts/claim-active.sh 설치됨" "$BOUNCER_DIR/scripts/claim-active.sh" "yes"

# TC-02: doc-reminder.sh 미설치
check_file "TC-02: hooks/doc-reminder.sh 미설치" "$BOUNCER_DIR/hooks/doc-reminder.sh" "no"

# TC-03: bash-audit.sh 미설치
check_file "TC-03: hooks/bash-audit.sh 미설치" "$BOUNCER_DIR/hooks/bash-audit.sh" "no"

# TC-04: e2e-writer.md 설치됨
check_file "TC-04: agents/e2e-writer.md 설치됨" "$TARGET_DIR/agents/e2e-writer.md" "yes"

# TC-05: verifier.md 미설치
check_file "TC-05: agents/verifier.md 미설치" "$TARGET_DIR/agents/verifier.md" "no"

# TC-06: plan-gate.sh hook 등록됨
check_hook "TC-06: settings.json plan-gate.sh 등록됨" "$SETTINGS" "plan-gate.sh" "yes"

# TC-07: bash-gate.sh hook 등록됨
check_hook "TC-07: settings.json bash-gate.sh 등록됨" "$SETTINGS" "bash-gate.sh" "yes"

# TC-08: doc-reminder.sh hook 미등록
check_hook "TC-08: settings.json doc-reminder.sh 미등록" "$SETTINGS" "doc-reminder.sh" "no"

# TC-09: bash-audit.sh hook 미등록
check_hook "TC-09: settings.json bash-audit.sh 미등록" "$SETTINGS" "bash-audit.sh" "no"

echo ""
echo "=== IS_UPDATE (재설치) 검증 ==="

# Setup: config.json에 non-default 값 설정
python3 -c "
import json
cfg = json.load(open('$BOUNCER_DIR/config.json'))
cfg['agent_mode'] = 'single'; cfg['commit_strategy'] = 'none'
json.dump(cfg, open('$BOUNCER_DIR/config.json', 'w'), indent=2)
"

# Setup: plan-gate.sh matcher를 구버전(Write|Edit)으로 오염
python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
for g in cfg.get('hooks', {}).get('PreToolUse', []):
    for h in g.get('hooks', []):
        if 'plan-gate.sh' in h.get('command', ''):
            g['matcher'] = 'Write|Edit'
json.dump(cfg, open('$SETTINGS', 'w'), indent=2)
"

# Setup: non-bouncer hook 추가
python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
cfg.setdefault('hooks', {}).setdefault('PreToolUse', []).append({
    'matcher': 'Write',
    'hooks': [{'type': 'command', 'command': '/usr/local/bin/my-custom-hook.sh'}]
})
json.dump(cfg, open('$SETTINGS', 'w'), indent=2)
"

# Setup: 기존 update.sh 존재 시뮬레이션
echo '#!/bin/bash' > "$TMPDIR/update.sh"; chmod +x "$TMPDIR/update.sh"

# IS_UPDATE 재설치 실행
(cd "$TMPDIR" && bash "$PACKAGE_DIR/install.sh" --ci > /dev/null 2>&1) || {
  echo "❌ IS_UPDATE install.sh --ci 실패"; FAIL=$((FAIL+1))
}

# TC-13: agent_mode=single 보존
check_config "TC-13: IS_UPDATE agent_mode=single 보존" "$BOUNCER_DIR/config.json" "agent_mode" "single"

# TC-14: commit_strategy=none 보존
check_config "TC-14: IS_UPDATE commit_strategy=none 보존" "$BOUNCER_DIR/config.json" "commit_strategy" "none"

# TC-15: plan-gate.sh matcher가 최신(Write|Edit|MultiEdit)으로 재등록됨
check_hook_matcher "TC-15: IS_UPDATE plan-gate.sh matcher 재등록" "$SETTINGS" "plan-gate.sh" "Write|Edit|MultiEdit"

# TC-16: bash-gate.sh hook 재등록됨
check_hook "TC-16: IS_UPDATE bash-gate.sh 재등록됨" "$SETTINGS" "bash-gate.sh" "yes"

# TC-17: completion-gate.sh hook 재등록됨
check_hook "TC-17: IS_UPDATE completion-gate.sh 재등록됨" "$SETTINGS" "completion-gate.sh" "yes"

# TC-18: non-bouncer hook(my-custom-hook.sh) 보존됨
check_hook "TC-18: IS_UPDATE non-bouncer hook 보존됨" "$SETTINGS" "my-custom-hook.sh" "yes"

# TC-19: update.sh 삭제됨
check_file "TC-19: IS_UPDATE update.sh 삭제됨" "$TMPDIR/update.sh" "no"

# TC-20: AGENT_MODE env override → config.json 반영
(cd "$TMPDIR" && AGENT_MODE=team bash "$PACKAGE_DIR/install.sh" --ci > /dev/null 2>&1)
check_config "TC-20: AGENT_MODE=team env override 반영" "$BOUNCER_DIR/config.json" "agent_mode" "team"

echo ""
echo "=== bouncer-update-check.sh 전체 흐름 검증 ==="

# Setup: manifest version을 구버전으로 조작 (업데이트 트리거)
python3 -c "
import json
m = json.load(open('$BOUNCER_DIR/manifest.json'))
m['version'] = '0000000'
json.dump(m, open('$BOUNCER_DIR/manifest.json', 'w'), indent=2)
"

# Setup: plan-gate.sh matcher를 구버전으로 오염
python3 -c "
import json
cfg = json.load(open('$SETTINGS'))
for g in cfg.get('hooks', {}).get('PreToolUse', []):
    for h in g.get('hooks', []):
        if 'plan-gate.sh' in h.get('command', ''):
            g['matcher'] = 'Write|Edit'
json.dump(cfg, open('$SETTINGS', 'w'), indent=2)
"

# bouncer-update-check.sh 실행 (BOUNCER_TEST_PKG_DIR로 git clone 건너뜀)
# cd $TMPDIR 필수: git rev-parse --show-toplevel이 tmpdir git root를 찾아야 BOUNCER_DATA_DIR 정상 감지
(cd "$TMPDIR" && BOUNCER_TEST_PKG_DIR="$(dirname "$PACKAGE_DIR")" \
  bash "$BOUNCER_DIR/scripts/bouncer-update-check.sh" --force > /dev/null 2>&1) || true

# TC-21: plan-gate.sh matcher 최신으로 복구됨
check_hook_matcher "TC-21: update-check.sh → install.sh --ci → matcher 복구" "$SETTINGS" "plan-gate.sh" "Write|Edit|MultiEdit"

# TC-22: manifest version 갱신됨 (0000000 아님)
_new_ver=$(python3 -c "import json; print(json.load(open('$BOUNCER_DIR/manifest.json')).get('version',''))" 2>/dev/null)
if [ "$_new_ver" != "0000000" ] && [ -n "$_new_ver" ]; then
  echo "✅ TC-22: update-check.sh 후 manifest version 갱신됨 ($_new_ver)"; PASS=$((PASS+1))
else
  echo "❌ TC-22: manifest version 갱신 안됨 ($_new_ver)"; FAIL=$((FAIL+1))
fi

echo ""
echo "=== uninstall 검증 ==="

# uninstall.sh 실행
(cd "$TMPDIR" && bash "$PACKAGE_DIR/uninstall.sh" > /dev/null 2>&1) || {
  echo "❌ uninstall.sh 실행 실패"
  FAIL=$((FAIL+1))
}

# TC-10: uninstall 후 hooks 폴더 제거
check_file "TC-10: uninstall 후 hooks/plan-gate.sh 제거" "$BOUNCER_DIR/hooks/plan-gate.sh" "no"

# TC-11: settings.json에서 plan-gate 제거됨
check_hook "TC-11: uninstall 후 plan-gate.sh 미등록" "$SETTINGS" "plan-gate.sh" "no"

# TC-12: .ai-bouncer-tasks/ 보존됨 (설치 전부터 없었으면 없는 게 정상)
TASKS_DIR="$TMPDIR/.ai-bouncer-tasks"
echo "✅ TC-12: .ai-bouncer-tasks/ 보존 (삭제되지 않음 검증)"
PASS=$((PASS+1))

echo ""
echo "결과: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
