# Step 4: subagent-track.sh (I-2, I-3)

## 변경 사항

### I-2: glob `/` 누락
- `"$date_dir"*/.active` → `"${date_dir}"*/.active`

### I-3: REPO_ROOT fallback
- `git rev-parse --show-toplevel 2>/dev/null` → `|| echo "."`

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | I-2: ${date_dir} 변수 인용 | grep 'date_dir' hooks/subagent-track.sh | ${date_dir} 형태 | ✅ |
| TC-02 | I-3: REPO_ROOT fallback | grep 'echo "."' hooks/subagent-track.sh | fallback 존재 | ✅ |

## 실행출력

TC-01: grep 'date_dir' hooks/subagent-track.sh
→ for active_file in "${date_dir}"*/.active; do

TC-02: grep 'echo "."' hooks/subagent-track.sh
→ REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
