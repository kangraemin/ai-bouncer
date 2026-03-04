# Step 3: Issue 1-A — install.sh realpath 크로스플랫폼 수정

## 테스트 기준 (TC)

| TC | 검증 방법 | 기대 결과 |
|---|---|---|
| TC-1 | `grep -n 'realpath --relative-to' install.sh` | 결과 없음 |
| TC-2 | `grep -n 'os.path.relpath\|os\.path\.relpath' install.sh` | Python relpath 사용 확인 |
| TC-3 | `grep -n 'HOME.*claude.*skills' install.sh` | install_skill이 절대경로 저장 확인 |

## 구현 내용

`install.sh`:
- `copy_file()` 함수 line 236: `realpath --relative-to=...` → `python3 -c "import os; print(os.path.relpath(...))"`
- `install_hook()` 함수 line 304: 동일 수정
- `install_skill()` 함수: INSTALLED_FILES에 `~/.claude/skills/<name>/<file>` 절대경로 저장

## 테스트 결과

| TC | 결과 |
|---|---|
| TC-1 `realpath --relative-to` 없음 | ✅ PASS |
| TC-2 `os.path.relpath` 사용 (line 236, 304) | ✅ PASS |
| TC-3 skills 절대경로 저장 (line 247) | ✅ PASS |
