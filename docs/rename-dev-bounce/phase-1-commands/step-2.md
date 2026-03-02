# Step 2: 파일 내 커맨드명 변경 (# /dev-bounce, description 업데이트)

## 완료 기준
- `commands/dev-bounce.md` Line 5가 `# /dev-bounce`이어야 한다
- frontmatter `description` 필드가 `/dev-bounce`를 언급해야 한다 (예: `/dev-bounce` 포함 문자열)
- "Phase 3 Dev team" 등 내부 문맥의 `dev` 단어는 변경되지 않아야 한다
- `/dev-bounce` 외에 body 텍스트에서 의도치 않은 `/dev ` (슬래시+dev+공백) 치환이 없어야 한다

## 테스트 케이스

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | `commands/dev-bounce.md` 5번째 줄 확인 | `# /dev-bounce` | |
| TC-2 | frontmatter description 필드에 `/dev-bounce` 포함 여부 확인 | description에 `/dev-bounce` 문자열 존재 | |
| TC-3 | body 내 `# /dev` (헤딩 형태) 잔존 여부 확인 | 존재하지 않음 | |
| TC-4 | "Phase 3 Dev team" 등 내부 참조 단어 보존 확인 | `Dev` / `dev` 단어가 그대로 유지됨 | |
| TC-5 | body 내 `/dev ` (슬래시+dev+공백) 형태 잔존 여부 확인 | 존재하지 않음 | |

## 검증 명령어

```bash
# TC-1: Line 5 확인
sed -n '5p' commands/dev-bounce.md

# TC-2: frontmatter description에 /dev-bounce 포함 여부
python3 -c "
import re
with open('commands/dev-bounce.md') as f:
    content = f.read()
fm_match = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
if fm_match:
    desc_match = re.search(r'description:\s*(.+)', fm_match.group(1))
    print('description:', desc_match.group(1).strip() if desc_match else 'NOT FOUND')
else:
    print('frontmatter not found')
"

# TC-3: '# /dev' 헤딩 잔존 확인 (# /dev-bounce 는 허용, # /dev 단독은 불허)
grep -n '^# /dev$' commands/dev-bounce.md && echo 'FAIL: # /dev 잔존' || echo 'PASS: # /dev 없음'

# TC-4: 내부 Dev/dev 단어 보존 확인 (Phase 3 Dev team 등)
grep -n 'Dev Team\|Dev team\|dev_phases\|planner-dev' commands/dev-bounce.md | head -5

# TC-5: ' /dev ' (슬래시+dev+공백) 패턴 확인
grep -n ' /dev ' commands/dev-bounce.md && echo 'FAIL: /dev 공백 패턴 잔존' || echo 'PASS: /dev 공백 패턴 없음'
```
