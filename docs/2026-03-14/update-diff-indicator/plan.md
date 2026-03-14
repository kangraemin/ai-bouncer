# update.sh 변경 표시 + SKILL.md plan mode 흐름 수정

## 변경 파일별 상세

### `update.sh`
- **변경 이유**: 모든 파일에 ✓ 표시되어 실제 변경된 파일 구분 불가
- **Before**: `cp "$agent" "$dst"` + `ok "..."`
- **After**: `copy_if_changed "$agent" "$dst" "..."` — cmp -s로 비교, 동일하면 dim(·), 다르면 ✓
- **영향 범위**: agents, skills, hooks, lib, update.sh/uninstall.sh 복사 로직 전체

### `skills/dev-bounce/SKILL.md` + `.claude/skills/dev-bounce/SKILL.md`
- **변경 이유**: 아까 ExitPlanMode 제거했으나 accept UI가 안 뜨는 문제. 되돌리되 "계획 텍스트 출력 → ExitPlanMode" 순서로 변경
- **Before**: "Claude가 ExitPlanMode를 직접 호출하지 않는다"
- **After**: "계획 요약 텍스트 출력 후 ExitPlanMode 호출"

## 검증
- `bash update.sh` → 변경 없는 파일 `·`, 변경된 파일 `✓`, 마지막 요약
- SKILL.md diff 확인
