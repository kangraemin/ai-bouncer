# update.sh bootstrap 수정

## 변경 파일별 상세

### `update.sh`

- **변경 이유**: 구 버전 update.sh가 배포된 유저 프로젝트에서 실행 시, clone은 최신 소스를 받아오지만 실행 코드는 구 버전이라 새 스킬(update-bouncer 등)이 설치되지 않음
- **Before** (lines 39~47):
```bash
if [ ! -f "$PACKAGE_DIR/agents/intent.md" ]; then
  echo -e "${BOLD}최신 소스 다운로드 중...${NC}"
  TMPDIR_UPDATE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_UPDATE"' EXIT
  git clone --depth 1 "${AI_BOUNCER_REPO:-https://github.com/kangraemin/ai-bouncer.git}" "$TMPDIR_UPDATE/ai-bouncer" -q
  PACKAGE_DIR="$TMPDIR_UPDATE/ai-bouncer"
  echo -e "${GREEN}✓${NC}  다운로드 완료"
fi
```
- **After**:
```bash
if [ ! -f "$PACKAGE_DIR/agents/intent.md" ]; then
  echo -e "${BOLD}최신 소스 다운로드 중...${NC}"
  TMPDIR_UPDATE=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_UPDATE"' EXIT
  git clone --depth 1 "${AI_BOUNCER_REPO:-https://github.com/kangraemin/ai-bouncer.git}" "$TMPDIR_UPDATE/ai-bouncer" -q
  PACKAGE_DIR="$TMPDIR_UPDATE/ai-bouncer"
  echo -e "${GREEN}✓${NC}  다운로드 완료"

  # bootstrap: clone된 최신 update.sh로 재실행 (구 버전 코드 실행 방지)
  if [ "${_UPDATE_BOOTSTRAPPED:-}" != "1" ] && [ -f "$PACKAGE_DIR/update.sh" ]; then
    export _UPDATE_BOOTSTRAPPED=1
    exec bash "$PACKAGE_DIR/update.sh" "$@"
  fi
fi
```
- **영향 범위**: update.sh만 변경. `_UPDATE_BOOTSTRAPPED=1` 환경변수로 무한루프 방지. `exec`으로 현재 프로세스 교체, `"$@"`로 인자 전달.

## 검증

- 검증 명령어: `bash -n update.sh`
- 기대 결과: 오류 없음
