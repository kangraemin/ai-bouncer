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
| TC-1 | install.sh 본문에서 커밋 전략 선택 UI 코드 확인 | `per-step`, `per-phase`, `none` 3가지 옵션을 출력하는 코드 블록 존재 |  |
| TC-2 | install.sh 본문에서 커밋 스킬 감지 로직 확인 | `~/.claude/commands/commit.md` 또는 `.claude/commands/commit.md` 파일 존재 여부를 체크하는 조건문 존재 |  |
| TC-3 | install.sh 실행 후 생성된 config.json에 `commit_strategy` 키 존재 확인 | `config.json`에 `"commit_strategy"` 키가 `"per-step"`, `"per-phase"`, `"none"` 중 하나의 값으로 존재 |  |
| TC-4 | install.sh 실행 후 생성된 config.json에 `commit_skill` 키 존재 확인 | `config.json`에 `"commit_skill"` 키가 `true` 또는 `false` 값으로 존재 |  |
| TC-5 | install.sh 실행 후 생성된 config.json에 `target_dir` 키 존재 확인 | `config.json`에 `"target_dir"` 키가 실제 설치 경로(예: `~/.claude` 또는 `.claude`)로 존재 |  |
| TC-6 | `bash install.sh --config` 실행 시 커밋 전략 재설정 분기 진입 확인 | install.sh에 `--config` 인자를 처리하는 분기(조건문)가 존재하고, 해당 분기 내에서 커밋 전략 선택 UI를 다시 실행하여 config.json만 업데이트하는 코드 존재 |  |
