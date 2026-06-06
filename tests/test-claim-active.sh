#!/bin/bash
# claim-active.sh 세션 격리 회귀 테스트
# 다중 세션 동시 실행 시 전역 파일(/tmp/.ai-bouncer-current-session) 공유로 인한
# .active 오염(TOCTOU)을 재현·차단 검증한다.
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLAIM="$SCRIPT_DIR/scripts/claim-active.sh"
TMP=$(mktemp -d); PASS=0; FAIL=0
chk(){ [ "$2" = "$3" ] && { echo "✅ $1"; PASS=$((PASS+1)); } || { echo "❌ $1 (expected=$3 got=$2)"; FAIL=$((FAIL+1)); }; }

# TC-1: env 우선 — 전역 파일에 다른 세션 id가 있어도 env id가 .active에 박힌다 (오염 차단 핵심)
echo "OTHER-SESSION-LASTWRITER" > /tmp/.ai-bouncer-current-session
CLAUDE_CODE_SESSION_ID="my-real-session" bash "$CLAIM" "$TMP/a/.active"
chk "TC-1: env 우선(전역 무시)" "$(cat "$TMP/a/.active" 2>/dev/null)" "my-real-session"

# TC-2: 동시 두 세션 — 각자 자기 env id를 자기 .active에 (서로 오염 안 됨)
CLAUDE_CODE_SESSION_ID="sess-X" bash "$CLAIM" "$TMP/x/.active"
CLAUDE_CODE_SESSION_ID="sess-Y" bash "$CLAIM" "$TMP/y/.active"
chk "TC-2a: X 격리" "$(cat "$TMP/x/.active" 2>/dev/null)" "sess-X"
chk "TC-2b: Y 격리" "$(cat "$TMP/y/.active" 2>/dev/null)" "sess-Y"

# TC-3: env 부재 시 전역 파일 폴백 (하위 호환)
echo "fallback-id" > /tmp/.ai-bouncer-current-session
( unset CLAUDE_CODE_SESSION_ID; bash "$CLAIM" "$TMP/f/.active" )
chk "TC-3: env 없으면 전역 폴백" "$(cat "$TMP/f/.active" 2>/dev/null)" "fallback-id"

# TC-4: env·전역 모두 없으면 exit 1
rm -f /tmp/.ai-bouncer-current-session
( unset CLAUDE_CODE_SESSION_ID; bash "$CLAIM" "$TMP/n/.active" 2>/dev/null )
chk "TC-4: 둘 다 없으면 실패" "$?" "1"

rm -rf "$TMP"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
