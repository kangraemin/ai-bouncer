#!/usr/bin/env bash
# E2E tests for bash-audit.sh hook behavior (Layer 2)
# Usage: bash tests/test-bash-audit.sh

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; echo "       → $2"; ((FAIL_COUNT++)) || true; }

AUDIT_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/bash-audit.sh"

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; rm -f /tmp/.ai-bouncer-snapshot; }
trap cleanup EXIT

make_audit_input() {
  jq -n '{tool_name: "Bash", tool_input: {command: "dummy"}}'
}

# Create a git repo with initial commit
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init "$dir" -q
  touch "$dir/.gitkeep"
  git -C "$dir" add .gitkeep
  git -C "$dir" -c user.email=test@test.com -c user.name=Test commit -m "init" -q
}

# ---------------------------------------------------------------------------
# TC-A1: gate 활성 + 휴리스틱 미감지 쓰기 → audit가 복원
# ---------------------------------------------------------------------------
tc_a1() {
  local dir="$TMPDIR_ROOT/tc_a1"
  make_repo "$dir"

  # 기존 tracked 파일 생성 + 커밋
  echo "original" > "$dir/src.txt"
  git -C "$dir" add src.txt
  git -C "$dir" -c user.email=test@test.com -c user.name=Test commit -m "add src" -q

  # 스냅샷 생성 (bash-gate가 block할 때 저장하는 것과 동일)
  (cd "$dir" && { git diff --name-only; git ls-files --others --exclude-standard; } | sort > /tmp/.ai-bouncer-snapshot)

  # 파일 변경 (휴리스틱을 우회한 케이스 시뮬레이션)
  echo "hacked" > "$dir/src.txt"

  # audit 실행
  local out; out=$(cd "$dir" && make_audit_input | bash "$AUDIT_SCRIPT" 2>/dev/null)

  # 파일이 복원되었는지 확인
  local content; content=$(cat "$dir/src.txt")
  if [ "$content" = "original" ]; then
    pass "TC-A1: tracked 파일 변경 → audit가 복원"
  else
    fail "TC-A1: tracked 파일 변경 → audit가 복원" "content='$content' (expected 'original')"
  fi
}

# ---------------------------------------------------------------------------
# TC-A2: gate 활성 + 예외 경로 → 복원 안 함
# ---------------------------------------------------------------------------
tc_a2() {
  local dir="$TMPDIR_ROOT/tc_a2"
  make_repo "$dir"

  mkdir -p "$dir/docs/my-task"

  # 스냅샷 생성
  (cd "$dir" && { git diff --name-only; git ls-files --others --exclude-standard; } | sort > /tmp/.ai-bouncer-snapshot)

  # 예외 경로에 파일 쓰기
  echo "# Plan" > "$dir/docs/my-task/plan.md"

  # audit 실행
  local out; out=$(cd "$dir" && make_audit_input | bash "$AUDIT_SCRIPT" 2>/dev/null)

  # 예외 파일은 유지되어야 함
  if [ -f "$dir/docs/my-task/plan.md" ]; then
    pass "TC-A2: 예외 경로 (plan.md) → 복원 안 함"
  else
    fail "TC-A2: 예외 경로 (plan.md) → 복원 안 함" "plan.md가 삭제됨"
  fi
}

# ---------------------------------------------------------------------------
# TC-A3: gate 비활성 (스냅샷 없음) → audit 스킵
# ---------------------------------------------------------------------------
tc_a3() {
  local dir="$TMPDIR_ROOT/tc_a3"
  make_repo "$dir"

  # 스냅샷 없음 (gate가 비활성 = 조건 충족)
  rm -f /tmp/.ai-bouncer-snapshot

  # 파일 변경
  echo "new content" > "$dir/new-file.txt"

  # audit 실행
  local out; out=$(cd "$dir" && make_audit_input | bash "$AUDIT_SCRIPT" 2>/dev/null)

  # 파일이 유지되어야 함
  if [ -f "$dir/new-file.txt" ]; then
    pass "TC-A3: 스냅샷 없음 → audit 스킵 (파일 유지)"
  else
    fail "TC-A3: 스냅샷 없음 → audit 스킵 (파일 유지)" "파일이 삭제됨"
  fi
}

# ---------------------------------------------------------------------------
# TC-A4: gate 활성 + 여러 파일 변경 → 전부 복원
# ---------------------------------------------------------------------------
tc_a4() {
  local dir="$TMPDIR_ROOT/tc_a4"
  make_repo "$dir"

  # tracked 파일 2개 생성
  echo "file1" > "$dir/a.txt"
  echo "file2" > "$dir/b.txt"
  git -C "$dir" add a.txt b.txt
  git -C "$dir" -c user.email=test@test.com -c user.name=Test commit -m "add files" -q

  # 스냅샷
  (cd "$dir" && { git diff --name-only; git ls-files --others --exclude-standard; } | sort > /tmp/.ai-bouncer-snapshot)

  # 두 파일 모두 변경
  echo "hacked1" > "$dir/a.txt"
  echo "hacked2" > "$dir/b.txt"

  # audit 실행
  local out; out=$(cd "$dir" && make_audit_input | bash "$AUDIT_SCRIPT" 2>/dev/null)

  local c1; c1=$(cat "$dir/a.txt")
  local c2; c2=$(cat "$dir/b.txt")
  if [ "$c1" = "file1" ] && [ "$c2" = "file2" ]; then
    pass "TC-A4: 여러 파일 변경 → 전부 복원"
  else
    fail "TC-A4: 여러 파일 변경 → 전부 복원" "a.txt='$c1', b.txt='$c2'"
  fi
}

# ---------------------------------------------------------------------------
# TC-A5: gate 활성 + untracked 신규 파일 → rm으로 제거
# ---------------------------------------------------------------------------
tc_a5() {
  local dir="$TMPDIR_ROOT/tc_a5"
  make_repo "$dir"

  # 스냅샷 (신규 파일 없는 상태)
  (cd "$dir" && { git diff --name-only; git ls-files --others --exclude-standard; } | sort > /tmp/.ai-bouncer-snapshot)

  # untracked 파일 생성
  echo "exploit" > "$dir/exploit.ts"

  # audit 실행
  local out; out=$(cd "$dir" && make_audit_input | bash "$AUDIT_SCRIPT" 2>/dev/null)

  if [ ! -f "$dir/exploit.ts" ]; then
    pass "TC-A5: untracked 신규 파일 → rm으로 제거"
  else
    fail "TC-A5: untracked 신규 파일 → rm으로 제거" "exploit.ts가 여전히 존재"
  fi
}

# ---------------------------------------------------------------------------
# TC-A6: 스냅샷 없음 → audit 아무것도 안 함
# ---------------------------------------------------------------------------
tc_a6() {
  local dir="$TMPDIR_ROOT/tc_a6"
  make_repo "$dir"

  rm -f /tmp/.ai-bouncer-snapshot

  # Non-Bash 도구 → 스킵
  local out; out=$(cd "$dir" && echo '{"tool_name":"Write","tool_input":{}}' | bash "$AUDIT_SCRIPT" 2>/dev/null)

  # 아무 출력 없어야 함
  if [ -z "$out" ]; then
    pass "TC-A6: Non-Bash 도구 → audit 스킵"
  else
    fail "TC-A6: Non-Bash 도구 → audit 스킵" "unexpected output: $out"
  fi
}

# ---------------------------------------------------------------------------
# Run all TCs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}=== bash-audit.sh E2E Tests (Layer 2) ===${NC}"
echo ""

tc_a1; tc_a2; tc_a3; tc_a4; tc_a5; tc_a6

echo ""
echo "---"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✅ $PASS_COUNT/$TOTAL passed${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAIL_COUNT/$TOTAL failed${NC}"
  exit 1
fi
