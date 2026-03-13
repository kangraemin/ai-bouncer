# manifest 기반 agent 삭제로 커스텀 agent 보호

## 변경 파일별 상세

### `install.sh` (lines 344-351)
- **변경 이유**: 소스에 없는 agent 삭제 시 manifest 기반 필터링 추가
- **Before**:
```bash
# 소스에 없는 설치된 agent 파일 삭제
for installed in "$TARGET_DIR/agents/"*.md; do
  [ -f "$installed" ] || continue
  if [ ! -f "$PACKAGE_DIR/agents/$(basename "$installed")" ]; then
    rm -f "$installed"
    warn "$(basename "$installed") 삭제 (소스에 없음)"
  fi
done
```
- **After**:
```bash
# 소스에 없는 설치된 agent 파일 삭제 (manifest에 기록된 파일만 대상)
for installed in "$TARGET_DIR/agents/"*.md; do
  [ -f "$installed" ] || continue
  rel_path="agents/$(basename "$installed")"
  if [ -f "$MANIFEST" ] && ! python3 -c "import json,sys; files=json.load(open(sys.argv[1])).get('files',[]); sys.exit(0 if sys.argv[2] in files else 1)" "$MANIFEST" "$rel_path" 2>/dev/null; then
    continue
  fi
  if [ ! -f "$PACKAGE_DIR/agents/$(basename "$installed")" ]; then
    rm -f "$installed"
    warn "$(basename "$installed") 삭제 (소스에서 제거됨)"
  fi
done
```

### `update.sh` (lines 78-85)
- **변경 이유**: install.sh와 동일한 로직 적용 (MANIFEST 변수 선언 추가)

### `tests/e2e-full.sh` — Update 섹션
- **변경 이유**: 커스텀 agent 보호 TC 추가

## 검증
- 검증 명령어: `CI=true bash tests/e2e-full.sh`
- 기대 결과: 전체 통과
