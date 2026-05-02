---
name: bouncer-status
description: ai-bouncer 설치 상태, 설정, 건강 진단을 한눈에 보여줌. '바운서 상태', 'bouncer status', '설치 확인', 'bouncer 설정' 요청 시 트리거.
---

# /bouncer-status

ai-bouncer 설치 상태와 설정을 보여주는 스킬. **빠르게** 동작해야 한다.

## 2단계 출력

### Step 1: 설정 즉시 출력 (config.json 읽기만)

먼저 config.json을 읽어서 설정을 **즉시** 보여준다. python 스크립트 쓰지 말고 `cat`이나 `jq`로 빠르게.

```bash
# 로컬 우선, 없으면 전역
LOCAL_CONFIG="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ai-bouncer/config.json"
GLOBAL_CONFIG="$HOME/.claude/ai-bouncer/config.json"
```

출력:

```
📋 ai-bouncer 설정

  범위: global (~/.claude)
  커밋 전략: per-step
  커밋 스킬: true
  실행 모드: hooks
  에이전트 모드: team
  docs git 추적: false

건강 진단 중...
```

config.json이 없으면:
```
📋 ai-bouncer: ❌ 미설치
  로컬/전역 모두 config.json 없음.
  설치: bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```
→ 여기서 종료.

### Step 2: 건강 진단 (설정 출력 후)

"건강 진단 중..." 출력한 뒤 아래 항목을 확인한다.

#### 2-1. 업데이트 확인

bouncer-update-check.sh를 사용해서 업데이트 필요 여부를 확인한다.

```bash
# 로컬 또는 전역에서 bouncer-update-check.sh 찾기
UPDATE_CHECK="$TARGET_DIR/scripts/bouncer-update-check.sh"
[ -f "$UPDATE_CHECK" ] || UPDATE_CHECK="$HOME/.claude/scripts/bouncer-update-check.sh"

bash "$UPDATE_CHECK" --check-only 2>/dev/null
```

결과에 따라:
- `up-to-date` → `✅ 최신 버전`
- `update-available` → `⚠️ 업데이트 있음 (현재: xxx → 최신: yyy)`
- 실패 → `❓ 확인 불가`

**업데이트가 있으면** 진단 결과 출력 후 "업데이트할까요?" 라고 물어본다. 사용자가 동의하면 `/update-bouncer` 스킬을 실행한다.

#### 2-2. Hook 등록 상태

**매번 GitHub remote에서 최신 hooks.json을 fetch해서** required hooks 목록을 동적으로 구성한다.

```bash
REPO="${AI_BOUNCER_REPO:-kangraemin/ai-bouncer}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"
REMOTE_HOOKS_JSON=$(curl -sf --max-time 5 "$RAW_BASE/hooks/hooks.json" 2>/dev/null)
# fetch 실패 시 로컬 설치본 fallback
[ -z "$REMOTE_HOOKS_JSON" ] && REMOTE_HOOKS_JSON=$(cat "$BOUNCER_DATA_DIR/hooks/hooks.json" 2>/dev/null || echo "{}")
```

`REMOTE_HOOKS_JSON`에서 `{event: [{matcher, file}]}` 구조를 파싱해 hook 목록을 추출한다.

각 hook에 대해 **3단계 판정**:

```bash
# a. settings.json 등록 여부
# b. 파일 존재 여부 ($BOUNCER_DATA_DIR/hooks/<file>)
# c. 파일 내용 일치 여부:
REMOTE_FILE=$(curl -sf --max-time 3 "$RAW_BASE/hooks/<file>" 2>/dev/null)
LOCAL_FILE=$(cat "$BOUNCER_DATA_DIR/hooks/<file>" 2>/dev/null)
# md5 또는 sha256 비교
```

판정 기준:
- ✅ 등록됨 + 파일 존재 + 내용 최신 (remote와 일치)
- ⚠️ 등록됨 + 파일 존재 + 내용 구버전 (remote와 다름)
- ⚠️ 등록됨 + 파일 없음
- ❌ 미등록
- ❓ curl 실패로 확인 불가 (로컬 기준으로 fallback)

#### 2-3. CLAUDE.md 규칙

```bash
grep -q 'ai-bouncer-rule' "$TARGET_DIR/CLAUDE.md"
```

#### 2-4. 파일 무결성

앞서 2-2에서 fetch한 `REMOTE_HOOKS_JSON`의 모든 `file` 값을 추출해,
해당 hook 파일이 `$BOUNCER_DATA_DIR/hooks/` 하위에 실제 존재하고
내용이 remote와 일치하는지 확인한다. (2-2 fetch 데이터 재활용)

`manifest.json`은 보조 참고용 — remote hooks.json에 없는 파일은 체크 불필요.

#### 2-5. 활성 태스크

```bash
find .ai-bouncer-tasks -name ".active" 2>/dev/null
```

#### 진단 결과 출력

```
건강 진단 결과

  업데이트: ✅ 최신 버전
  Hook: ✅ 8/8 정상
  CLAUDE.md: ✅ 규칙 주입됨
  파일 무결성: ✅ 20/20
  활성 태스크: 없음
```

문제가 있을 때만 상세 표시:

```
건강 진단 결과

  업데이트: ⚠️ 업데이트 있음 (현재: abc1234 → 최신: def5678)
  Hook: ⚠️ 6/8
    ❌ subagent-track.sh — 미등록
    ⚠️ bash-gate.sh — 등록됨, 파일 없음
  CLAUDE.md: ❌ 규칙 없음
  파일 무결성: ⚠️ 18/20
    누락: agents/dev.md, agents/qa.md
  활성 태스크: my-task (development/normal)

  수정 방법: bash install.sh --config 또는 재설치

업데이트할까요?
```

## 규칙

- 읽기 전용 — 파일을 수정하지 않는다
- Step 1 (설정)을 먼저 출력한 뒤 Step 2 (진단)를 실행한다. 한번에 모으지 않는다.
- python 대신 jq/grep/bash를 써서 빠르게 동작한다
- 전역/로컬 둘 다 있으면 양쪽 다 보여준다
