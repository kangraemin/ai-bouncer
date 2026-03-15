---
description: ai-bouncer 최신 버전 확인 및 업데이트
---

# /update-bouncer

## 플로우

1. update-check.sh 경로 탐색:
   - 로컬: `<git-root>/.claude/scripts/update-check.sh`
   - 글로벌: `~/.claude/scripts/update-check.sh`
   - 둘 다 없으면 "update-check.sh를 찾을 수 없습니다. `bash update.sh`를 먼저 실행하세요." 출력 후 종료
2. `bash "<경로>/update-check.sh" --check-only` 로 현재/최신 버전 확인
3. 결과 출력:
   - `up-to-date` → "최신 버전입니다 (SHA)" 출력 후 종료
   - `update-available` → 현재/최신 SHA 보여주고 업데이트 여부 확인
4. 업데이트 확인 시 `bash "<경로>/update-check.sh" --force` 실행
5. 완료 메시지 출력
