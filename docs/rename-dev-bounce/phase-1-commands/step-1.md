# Step 1: commands/dev.md → commands/dev-bounce.md 파일 rename

## 완료 기준
- `commands/dev-bounce.md` 파일이 존재한다
- `commands/dev.md` 파일이 존재하지 않는다
- git이 해당 변경을 rename으로 인식한다 (`git status`에 rename 표시)

## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | `commands/dev-bounce.md` 파일 존재 여부 확인 | 파일이 존재함 (`test -f commands/dev-bounce.md` 성공) |  |
| TC-2 | `commands/dev.md` 파일 존재 여부 확인 | 파일이 존재하지 않음 (`test -f commands/dev.md` 실패) |  |
| TC-3 | `git status` 출력에서 rename 인식 여부 확인 | `git status` 출력에 `renamed: commands/dev.md -> commands/dev-bounce.md` 포함 |  |

## 구현

```bash
git mv commands/dev.md commands/dev-bounce.md
```

변경 파일:
- `commands/dev.md` → `commands/dev-bounce.md` (git rename)

## 실행 결과

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | `commands/dev-bounce.md` 파일 존재 여부 확인 | 파일이 존재함 | PASS |
| TC-2 | `commands/dev.md` 파일 존재 여부 확인 | 파일이 존재하지 않음 | PASS |
| TC-3 | `git status` 출력에서 rename 인식 여부 확인 | `renamed: commands/dev.md -> commands/dev-bounce.md` 포함 | PASS |
