# Step 3: 커밋 전략 선택 + config.json 저장 + --config 플래그

## 완료 기준

- install.sh에 커밋 전략 선택 UI 존재 (per-step / per-phase / none 3개 옵션)
- install.sh에 커밋 스킬 자동 감지 로직 존재 (`~/.claude/commands/commit.md` 또는 `.claude/commands/commit.md` 파일 존재 여부 체크)
- config.json 저장 시 `commit_strategy` 키 포함
- config.json 저장 시 `commit_skill` 키 포함 (boolean)
- config.json 저장 시 `target_dir` 키 포함 (uninstall용)
- `--config` 플래그로 커밋 전략만 재설정 가능한 분기 존재

## 테스트 케이스

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | install.sh 본문에서 커밋 전략 선택 UI 코드 확인 | `per-step`, `per-phase`, `none` 3가지 옵션을 출력하는 코드 블록 존재 | PASS |
| TC-2 | install.sh 본문에서 커밋 스킬 감지 로직 확인 | `~/.claude/commands/commit.md` 또는 `.claude/commands/commit.md` 파일 존재 여부를 체크하는 조건문 존재 | PASS |
| TC-3 | install.sh 실행 후 생성된 config.json에 `commit_strategy` 키 존재 확인 | `config.json`에 `"commit_strategy"` 키가 `"per-step"`, `"per-phase"`, `"none"` 중 하나의 값으로 존재 | PASS |
| TC-4 | install.sh 실행 후 생성된 config.json에 `commit_skill` 키 존재 확인 | `config.json`에 `"commit_skill"` 키가 `true` 또는 `false` 값으로 존재 | PASS |
| TC-5 | install.sh 실행 후 생성된 config.json에 `target_dir` 키 존재 확인 | `config.json`에 `"target_dir"` 키가 실제 설치 경로(예: `~/.claude` 또는 `.claude`)로 존재 | PASS |
| TC-6 | `bash install.sh --config` 실행 시 커밋 전략 재설정 분기 진입 확인 | install.sh에 `--config` 인자를 처리하는 분기(조건문)가 존재하고, 해당 분기 내에서 커밋 전략 선택 UI를 다시 실행하여 config.json만 업데이트하는 코드 존재 | PASS |

## 구현 내용

- `--config` 모드 분기를 `--uninstall` 블록 직후에 추가 (line 107)
  - config.json 미존재 시 에러 출력 후 exit 1
  - 커밋 전략 3가지 옵션 선택 UI
  - 커밋 스킬 재감지 (`~/.claude/commands/commit.md` 또는 `.claude/commands/commit.md`)
  - python3 인라인 스크립트로 config.json 부분 업데이트 (commit_strategy, commit_skill)
- docs/ 설정 섹션 직후 "커밋 전략" 헤더 추가
  - 3가지 옵션 선택 UI (per-step / per-phase / none, 기본값 1)
  - case 문으로 COMMIT_STRATEGY 변수 설정
  - commit.md 파일 존재 여부 체크로 COMMIT_SKILL_BOOL 설정
- config.json cat 블록에 `commit_strategy`, `commit_skill`, `target_dir` 키 추가

## 변경 파일

- `install.sh`: --config 분기 추가, 커밋 전략 선택 UI 추가, config.json 저장 필드 확장

## 빌드

```
bash -n install.sh
```

결과: SYNTAX OK
