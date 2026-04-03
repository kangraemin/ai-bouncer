---
name: bouncer-status
description: ai-bouncer 설치 상태, 설정, 건강 진단을 한눈에 보여줌. '바운서 상태', 'bouncer status', '설치 확인', 'bouncer 설정' 요청 시 트리거.
---

# /bouncer-status

ai-bouncer 설치 상태와 설정을 진단하고 보여주는 스킬.

## 플로우

아래 항목을 순서대로 확인하고 결과를 **단일 표**로 출력한다.

### 1. 설치 위치 감지

```bash
# 로컬 설치 확인
LOCAL_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude"
LOCAL_MANIFEST="$LOCAL_DIR/ai-bouncer/manifest.json"

# 전역 설치 확인
GLOBAL_DIR="$HOME/.claude"
GLOBAL_MANIFEST="$GLOBAL_DIR/ai-bouncer/manifest.json"
```

- 로컬 manifest 있으면 → `scope: local`
- 전역 manifest 있으면 → `scope: global`
- 둘 다 있으면 → `scope: both (로컬 우선)`
- 둘 다 없으면 → `scope: 미설치`

### 2. 버전 정보

manifest.json에서 읽는다:
```bash
jq -r '.version // "unknown"' "$MANIFEST"
jq -r '.installed_at // "unknown"' "$MANIFEST"
```

### 3. 설정 확인

config.json에서 읽는다:
```bash
CONFIG="$BOUNCER_DATA_DIR/config.json"
```

확인 항목:
- `mode`: simple / normal
- `commit_strategy`: per-step / per-phase / manual
- `commit_skill`: true/false
- `enforcement_mode`: hooks / rules
- `agent_mode`: duo / team / solo
- `docs_git_track`: true/false

### 4. Hook 등록 상태

settings.json에서 bouncer hook 등록 여부 확인:

```
필수 hooks:
- PreToolUse: plan-gate.sh (Write|Edit|MultiEdit)
- PreToolUse: bash-gate.sh (Bash)
- PostToolUse: doc-reminder.sh (Write|Edit|MultiEdit)
- PostToolUse: bash-audit.sh (Bash)
- Stop: completion-gate.sh
- Stop: stop-active-cleanup.sh
- SubagentStart: subagent-track.sh
- SubagentStop: subagent-cleanup.sh
```

각 hook에 대해:
- ✅ 등록됨 + 파일 존재
- ⚠️ 등록됨 + 파일 없음
- ❌ 미등록

### 5. CLAUDE.md 규칙 주입

```bash
grep -q 'ai-bouncer-rule' "$TARGET_DIR/CLAUDE.md"
```

- ✅ 규칙 있음
- ❌ 규칙 없음

### 6. 파일 무결성

manifest.json의 files 배열과 실제 파일 존재 여부 비교:
- 누락 파일 있으면 목록 출력
- 전부 있으면 ✅

### 7. 활성 태스크

```bash
find .ai-bouncer-tasks -name ".active" 2>/dev/null
```

활성 태스크가 있으면 태스크명 + workflow_phase + mode 출력.

## 출력 포맷

```
📋 ai-bouncer 상태

설치
  범위: local | global | both | 미설치
  버전: abc1234
  설치일: 2026-04-03T...
  파일 무결성: ✅ 전체 N개 | ⚠️ N개 누락

설정
  모드: normal
  커밋 전략: per-step
  커밋 스킬: ✅
  실행 모드: hooks
  에이전트 모드: team
  docs git 추적: false

Hook 상태
  ✅ plan-gate.sh (PreToolUse: Write|Edit|MultiEdit)
  ✅ bash-gate.sh (PreToolUse: Bash)
  ✅ doc-reminder.sh (PostToolUse: Write|Edit|MultiEdit)
  ✅ bash-audit.sh (PostToolUse: Bash)
  ✅ completion-gate.sh (Stop)
  ✅ stop-active-cleanup.sh (Stop)
  ✅ subagent-track.sh (SubagentStart)
  ✅ subagent-cleanup.sh (SubagentStop)

CLAUDE.md: ✅ 규칙 주입됨

활성 태스크: 없음 | task-name (development/normal)
```

## 문제 발견 시

문제가 있으면 마지막에 **수정 제안** 섹션 추가:

```
⚠️ 문제 발견
  - hook 미등록: bash-gate.sh → `bash install.sh --config` 또는 재설치 필요
  - 파일 누락: agents/dev.md → 재설치 필요
  - CLAUDE.md 규칙 없음 → `bash install.sh --config` 실행
```

## 규칙

- 읽기 전용 — 파일을 수정하지 않는다
- 문제 발견 시 수정 명령어만 제안하고, 직접 실행하지 않는다
- 전역/로컬 둘 다 있으면 양쪽 다 보여준다
