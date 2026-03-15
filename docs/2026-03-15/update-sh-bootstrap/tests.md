# update.sh bootstrap TC

| TC | 검증 항목 | 기대 결과 | 상태 |
|----|----------|----------|------|
| TC-01 | 구문 검사 | `bash -n` 오류 없음 | ✅ |
| TC-02 | `_UPDATE_BOOTSTRAPPED=1`일 때 clone 없이 실행 | 정상 실행 (clone 스킵) | ✅ |
| TC-03 | bootstrap 코드가 clone 블록 안에 위치 | diff에서 `PACKAGE_DIR=` 아래에 bootstrap 블록 확인 | ✅ |

## 실행출력

TC-01: `bash -n update.sh`
→ (출력 없음 — PASS)

TC-02: `_UPDATE_BOOTSTRAPPED=1 bash update.sh` (이 프로젝트에서 실행 — agents/intent.md 존재하므로 clone 분기 진입 안 함, 정상 실행)
→ 정상 실행 완료

TC-03: `git diff update.sh`
```diff
@@ -44,6 +44,12 @@ if [ ! -f "$PACKAGE_DIR/agents/intent.md" ]; then
   git clone ...
   PACKAGE_DIR="$TMPDIR_UPDATE/ai-bouncer"
   echo -e "${GREEN}✓${NC}  다운로드 완료"
+
+  # bootstrap: clone된 최신 update.sh로 재실행 (구 버전 코드 실행 방지)
+  if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ] && [ -f "$PACKAGE_DIR/update.sh" ]; then
+    export _UPDATE_BOOTSTRAPPED=1
+    exec bash "$PACKAGE_DIR/update.sh" "$@"
+  fi
 fi
```
→ clone 블록(`PACKAGE_DIR=` 아래) 안에 정확히 위치 확인
