# 개발 Phase 1: commands 레이어 변경

## 개발 범위

- 구현할 기능:
  - 기능 1: `commands/dev.md` → `commands/dev-bounce.md` 파일 이름 변경 (git mv)
  - 기능 2: 파일 내부 커맨드명 변경 (`# /dev` → `# /dev-bounce`, description 업데이트)
  - 기능 5: Phase 1 진입 시 `EnterPlanMode` 호출, `ExitPlanMode` 후 승인 요청 흐름 추가
- 관련 파일/컴포넌트:
  - `commands/dev.md` (rename 대상)
  - `commands/dev-bounce.md` (rename 결과물 + 내용 수정)

## Step 목록

- Step 1: `commands/dev.md` → `commands/dev-bounce.md` 파일 rename
  - 완료 기준: `commands/dev-bounce.md` 존재, `commands/dev.md` 삭제됨, `git status`에서 rename 확인 가능
- Step 2: 파일 내 커맨드명 변경
  - 완료 기준: `dev-bounce.md` 5번 줄이 `# /dev-bounce`로 변경됨, description frontmatter에 `/dev-bounce` 반영됨
- Step 3: Plan mode 흐름 추가 (기능 5)
  - 완료 기준: Phase 1 진입 직후 `EnterPlanMode` 호출 지시 추가, streak=3 후 `ExitPlanMode` + 승인 요청 흐름, 수정 요청 시 `EnterPlanMode` 재진입 흐름이 `dev-bounce.md` 본문에 명시됨

## 이 Phase 완료 기준

- `commands/dev-bounce.md` 파일이 올바른 내용으로 존재
- `commands/dev.md` 파일이 삭제됨
- 헤딩 `# /dev-bounce`, description `/dev-bounce` 슬래시 커맨드 지칭 반영
- plan mode 흐름이 Phase 1 섹션에 올바르게 반영됨
- 모든 Step의 `[STEP:N:테스트통과]` 확인됨
