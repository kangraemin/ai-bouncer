---
description: ai-bouncer 최신 버전 확인 및 업데이트
---

# /update-bouncer

## Step 1: 버전 확인

아래 코드를 그대로 실행한다. 경로나 파일명을 변경하지 않는다.

```bash
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
SCRIPT=""
for path in \
  "$GIT_ROOT/.claude/ai-bouncer/scripts/bouncer-update-check.sh" \
  "$GIT_ROOT/.claude/scripts/bouncer-update-check.sh" \
  "$HOME/.claude/ai-bouncer/scripts/bouncer-update-check.sh" \
  "$HOME/.claude/scripts/bouncer-update-check.sh"; do
  [ -f "$path" ] && SCRIPT="$path" && break
done
if [ -z "$SCRIPT" ]; then
  echo "bouncer-update-check.sh를 찾을 수 없습니다. bash update.sh를 먼저 실행하세요."
  exit 1
fi
bash "$SCRIPT" --check-only
```

## Step 2: 결과 처리

- `status: up-to-date` → "최신 버전입니다 (SHA)" 출력 후 종료
- `status: update-available` → 현재/최신 SHA 보여주고 사용자에게 업데이트 여부 확인

## Step 3: 업데이트 실행 (사용자 승인 시)

```bash
bash "$SCRIPT" --force
```
