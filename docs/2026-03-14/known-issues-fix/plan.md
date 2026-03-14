# 알려진 이슈 2개 수정

## 변경 파일별 상세

### `install.sh`
- **변경 이유**: `--update` 주석이 있지만 실제 코드에 분기 없음. `update.sh`가 이미 비대화형 업데이트 제공.
- **Before** (현재 코드):
```bash
# ai-bouncer install/update/uninstall
# Usage:
#   bash install.sh            — 신규 설치 또는 업데이트
#   bash install.sh --update   — 최신 파일로 업데이트
#   bash install.sh --uninstall — 제거
```
- **After** (변경 후):
```bash
# ai-bouncer install/update/uninstall
# Usage:
#   bash install.sh            — 신규 설치 또는 업데이트
#   bash install.sh --uninstall — 제거
```
- **영향 범위**: 없음 (주석만 제거)

### `skills/dev-bounce/SKILL.md`
- **변경 이유**: Phase 0-B 중복 문장 제거 + `.active` 파일 why 보강
- **Before** (line 120):
```
`[INTENT:개발요청]` 수신 후 TASK_DIR을 초기화한다. **복잡도 판별은 하지 않는다** (Phase 1-B에서 plan 기반으로 판별).
```
- **After**:
```
TASK_DIR을 초기화한다. **복잡도 판별은 하지 않는다** — Phase 1-B에서 plan 기반으로 판별하기 때문.
```
- **Before** (line 127):
```
4. `.active` 파일 생성 (빈 파일 — hook이 session_id를 자동 claim)
```
- **After**:
```
4. `.active` 파일 생성 (빈 파일 — hook이 session_id를 자동 claim하여 세션 간 충돌 방지)
```
- **영향 범위**: 설치된 `.claude/skills/dev-bounce/SKILL.md`에도 동일 적용 필요 (`update.sh` 실행으로 반영)

## 검증
- 검증 명령어: `bash tests/e2e-full.sh`
- 기대 결과: 57건 전체 통과
