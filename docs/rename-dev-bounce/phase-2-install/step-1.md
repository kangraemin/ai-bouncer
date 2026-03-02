# Step 1: install.sh copy_file 경로 및 완료 메시지 변경

## 완료 기준
- `copy_file` 호출이 `commands/dev-bounce.md` 경로를 사용한다
- `copy_file` 호출에서 `commands/dev.md` 경로가 제거된다
- 설치 완료 메시지에 `dev-bounce.md (/dev-bounce)` 문자열이 포함된다
- 설치 완료 메시지에 `dev.md (/dev)` 문자열이 없다

## 테스트 케이스
| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | install.sh에 `copy_file "$PACKAGE_DIR/commands/dev-bounce.md" "$TARGET_DIR/commands/dev-bounce.md"` 라인 존재 여부 확인 | 해당 라인이 존재한다 | PASS |
| TC-2 | install.sh에 `copy_file "$PACKAGE_DIR/commands/dev.md"` 라인 존재 여부 확인 | 해당 라인이 존재하지 않는다 (제거됨) | PASS |
| TC-3 | 완료 메시지 라인(echo)에 `dev-bounce.md (/dev-bounce)` 포함 여부 확인 | 해당 문자열이 포함된다 | PASS |
| TC-4 | 완료 메시지 라인(echo)에 `dev.md (/dev)` 포함 여부 확인 | 해당 문자열이 존재하지 않는다 | PASS |

## 구현 내용
- `install.sh` 228번째 줄: `copy_file` 경로를 `commands/dev.md` → `commands/dev-bounce.md`로 변경
- `install.sh` 339번째 줄: 완료 메시지를 `dev.md (/dev)` → `dev-bounce.md (/dev-bounce)`로 변경

## 변경 파일
- `install.sh`: copy_file 경로 및 완료 메시지 내 명령어 슬래그 변경

## 빌드
빌드 명령: `bash -n /Users/ram/programming/vibecoding/ai-bouncer/install.sh`
결과: 성공 (syntax check)
