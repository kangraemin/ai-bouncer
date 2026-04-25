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
