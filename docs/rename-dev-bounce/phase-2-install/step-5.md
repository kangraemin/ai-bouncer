# Step 5: uninstall 시 CLAUDE.md 블록 제거

## 완료 기준

- `--uninstall` 실행 시 CLAUDE.md에서 `# --- ai-bouncer-rule start ---` ~ `# --- ai-bouncer-rule end ---` 블록을 제거한다.
- 블록 제거 대상 경로는 `config.json`의 `target_dir` 값에서 결정한다.
- 블록 외 나머지 내용은 보존된다.
- 블록이 없으면 에러 없이 통과한다.
- install.sh 전체에 bash 문법 오류가 없다.

## 테스트 케이스

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | install.sh --uninstall 섹션(설치 범위 감지 이후 ~ exit 0 이전) 내 CLAUDE.md 블록 제거 로직 코드 존재 확인 | `ai-bouncer-rule` 마커를 다루는 코드가 uninstall 섹션에 존재 |  |
| TC-2 | config.json에서 target_dir을 읽어 CLAUDE.md 경로를 결정하는 로직 존재 확인 | `$HOME/.claude/ai-bouncer/config.json` 또는 동등한 경로에서 `target_dir`을 파싱하여 CLAUDE.md 경로를 구성하는 코드가 존재 |  |
| TC-3 | 블록(start~end 마커) 제거 후 나머지 내용 보존 로직 존재 확인 | 블록 앞/뒤 문자열을 이어붙여 파일에 쓰는 코드가 존재 (마커 밖 내용 유실 없음) |  |
| TC-4 | 블록이 없을 때 no-op(에러 없이 통과)하는 분기 존재 확인 | 마커를 찾지 못한 경우 파일을 수정하지 않고 종료하는 분기가 코드에 존재 |  |
| TC-5 | `bash -n install.sh` 실행 | 문법 오류 없이 종료 코드 0 반환 | PASS |

## 구현 내용

- `--uninstall` 섹션의 settings.json hook 제거 블록(`fi`) 직후, 매니페스트 삭제 라인 직전에 CLAUDE.md 블록 제거 로직 삽입
- `$HOME/.claude/ai-bouncer/config.json`에서 `target_dir` 읽어 `$UNINSTALL_TARGET_DIR/CLAUDE.md` 경로 결정
- Python heredoc으로 `# --- ai-bouncer-rule start ---` ~ `# --- ai-bouncer-rule end ---` 마커 블록 제거
- 블록 없을 시 no-op 처리 (에러 없이 통과)
- 앞뒤 빈줄 정리 후 나머지 내용 보존

## 변경 파일

- `install.sh`: `--uninstall` 섹션에 CLAUDE.md 블록 제거 로직 추가 (line 97 이후)

## 빌드

```
bash -n install.sh → 종료 코드 0 (문법 오류 없음)
```
