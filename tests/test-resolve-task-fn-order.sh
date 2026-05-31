#!/bin/bash
# delegated 세션에서도 _get_phase_folder가 정의되고 정상 동작하는지 검증
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RT="$REPO/hooks/lib/resolve-task.sh"
PASS=0; FAIL=0
ok(){ echo "✅ $1"; PASS=$((PASS+1)); }
ng(){ echo "❌ $1"; FAIL=$((FAIL+1)); }

# 임시 task: phase-2-theme 폴더 존재
TMP=$(mktemp -d)
TD="$TMP/.ai-bouncer-tasks/2026-01-01/t"; mkdir -p "$TD/phase-2-theme"
cat > "$TD/state.json" <<'EOF'
{"workflow_phase":"development","dev_phases":{"2":{"folder":"phase-2-theme","steps":{"1":"x"}}}}
EOF
APPROVED=/tmp/.ai-bouncer-approved-agents
SID="fnorder-test-$$"
BK="$TMP/approved.bak"; cp "$APPROVED" "$BK" 2>/dev/null || : > "$BK"
echo "${SID}|${TD}" >> "$APPROVED"
restore(){ cp "$BK" "$APPROVED" 2>/dev/null || true; rm -rf "$TMP"; }
trap restore EXIT

# TC-1: delegated 세션 source → _get_phase_folder 정의됨
OUT=$(SESSION_ID="$SID" bash -c 'cd "'"$TMP"'"; source "'"$RT"'"; echo "DELEG=$IS_DELEGATED_AGENT"; type _get_phase_folder >/dev/null 2>&1 && echo DEFINED || echo MISSING')
echo "$OUT" | grep -q "DELEG=true" && ok "TC-1: delegated로 resolve됨" || ng "TC-1: delegated 아님 ($OUT)"
echo "$OUT" | grep -q "DEFINED" && ok "TC-1: _get_phase_folder 정의됨" || ng "TC-1: 함수 미정의(버그)"

# TC-2: delegated 세션에서 _get_phase_folder가 올바른 폴더명 반환
OUT2=$(SESSION_ID="$SID" bash -c 'cd "'"$TMP"'"; source "'"$RT"'"; _get_phase_folder "$STATE_FILE" 2')
[ "$OUT2" = "phase-2-theme" ] && ok "TC-2: 폴더명 정확(phase-2-theme)" || ng "TC-2: 폴더명 틀림 ($OUT2)"

# TC-3: 일반(non-delegated) 세션도 여전히 정의됨 (회귀 방지)
OUT3=$(SESSION_ID="nope-$$" bash -c 'cd "'"$TMP"'"; source "'"$RT"'"; type _get_phase_folder >/dev/null 2>&1 && echo DEFINED || echo MISSING')
echo "$OUT3" | grep -q "DEFINED" && ok "TC-3: 일반 세션 _get_phase_folder 정의됨" || ng "TC-3: 회귀"

echo ""; echo "결과: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] || exit 1
