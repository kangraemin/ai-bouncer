# Subagent 모드 state 추적 버그 수정 + E2E 커버리지 보강

## Context
claudeInspector에서 `agent_mode: "subagent"` 사용 시 state.json이 `dev_phases: {}`, 카운터 0인 채로 `done` 찍히는 문제. SKILL.md에 subagent state.json 업데이트 지시 누락 + e2e 미커버 + backup 파일 미정리.

## 변경 파일별 상세

### `skills/dev-bounce/SKILL.md`

#### 1-A. Phase 3 subagent state.json 업데이트 의무 명시
- **변경 이유**: subagent Lead/Dev/QA가 state.json 카운터 업데이트 지시 없음
- **Before** (line 330):
```markdown
**subagent/single 모드**: Lead에게 agent_mode를 전달. team_name은 빈 문자열로 유지.
```
- **After**:
```markdown
**subagent/single 모드**: Lead에게 agent_mode를 전달. team_name은 빈 문자열로 유지.

> **subagent/single 모드 state.json 업데이트 의무:**
>
> team 모드와 동일하게, 다음 시점에 state.json을 반드시 업데이트한다:
> - **Lead**: `dev_phases` 초기화 후 `current_dev_phase = 1`, `current_step = 1` 설정
> - **QA** (또는 Lead가 겸임 시 Lead): Step 테스트 통과 시 `current_step++`
> - **Lead**: Phase 완료 시 `current_dev_phase++`, `current_step = 1` 리셋
>
> plan-gate/bash-gate가 이 카운터와 아티팩트 파일을 모두 검증하므로, 카운터 미업데이트 시 다음 step 코드 수정이 차단된다.
> single 모드에서는 Main Claude가 직접 이 업데이트를 수행한다.
```
- **영향 범위**: NORMAL 모드 subagent/single 워크플로우

#### 1-B. SIMPLE 모드 state.json 필드 기대값 명시
- **변경 이유**: SIMPLE에서 dev_phases/counters 비어있는 게 정상인지 불명확
- **Before** (line 222):
```markdown
Main Claude가 직접 코드 수정 (phase/step 구조 없이 자유롭게).
```
- **After**:
```markdown
Main Claude가 직접 코드 수정 (phase/step 구조 없이 자유롭게).

> SIMPLE 모드에서는 `dev_phases`, `current_dev_phase`, `current_step`을 사용하지 않는다 (빈 객체/0 유지가 정상).
> hook은 SIMPLE 모드에서 이 필드를 검증하지 않는다.
```
- **영향 범위**: SIMPLE 모드 전체

### `install.sh`

#### 2-A. 백업 파일 정리
- **변경 이유**: update마다 `.backup-YYYYMMDD` 파일 누적
- **Before** (line 729-731):
```bash
ok "매니페스트 저장됨"

# ── 완료 ──────────────────────────────────────────────────────
```
- **After**:
```bash
ok "매니페스트 저장됨"

# ── 백업 파일 정리 ──────────────────────────────────────────────
BACKUP_COUNT=0
while IFS= read -r -d '' backup; do
  rm -f "$backup"
  BACKUP_COUNT=$((BACKUP_COUNT + 1))
done < <(find "$TARGET_DIR" -name "*.backup-*" -print0 2>/dev/null)
[ "$BACKUP_COUNT" -gt 0 ] && ok "${BACKUP_COUNT}개 백업 파일 정리됨"

# ── 완료 ──────────────────────────────────────────────────────
```
- **영향 범위**: install/update 완료 후 정리

### `tests/e2e-hooks.sh`

#### 3-A. Subagent 모드 hook 동작 TC 5건 + SIMPLE 모드 TC 2건

### `tests/e2e-full.sh`

#### 4-A. CLAUDE.md 콘텐츠 보존 TC 3건 + 백업 정리 TC 2건

## 검증
- 검증 명령어: `bash tests/e2e-full.sh && bash tests/e2e-hooks.sh`
- 기대 결과: 기존 + 신규 TC 전부 통과
