# 구현 계획

## 요청 요약

- `commands/dev.md` 파일을 `commands/dev-bounce.md`로 이름 변경
- 파일 내부의 커맨드명 헤딩 `/dev` → `/dev-bounce` 변경
- `install.sh`에서 복사 대상 파일명을 `dev-bounce.md`로 반영
- `install.sh` 설치 시 설치 범위(global/local)에 맞는 CLAUDE.md에 `/dev-bounce` 강제 호출 규칙 자동 주입

---

## 기능 목록

### 기능 1: commands/dev.md → commands/dev-bounce.md 파일 이름 변경

- 설명: 파일 시스템 레벨 rename. 기존 `dev.md`를 `dev-bounce.md`로 변경.
- 핵심 요구사항:
  - `commands/dev.md` 파일 삭제 후 `commands/dev-bounce.md`로 재생성 또는 git mv

### 기능 2: 파일 내부 커맨드명 변경

- 설명: `commands/dev-bounce.md` 내 `# /dev` 헤딩을 `# /dev-bounce`로 교체
- 핵심 요구사항:
  - 5번 줄 `# /dev` → `# /dev-bounce`
  - description frontmatter의 설명 문자열은 `/dev-bounce` 슬래시 커맨드로 지칭하도록 업데이트
  - 본문 내 다른 `/dev` 참조(일반 텍스트 설명 컨텍스트)는 변경 불필요

### 기능 3: install.sh 복사 경로 반영

- 설명: install.sh 228번 줄의 `copy_file` 대상을 `dev-bounce.md`로 변경
- 핵심 요구사항:
  - 변경 전: `copy_file "$PACKAGE_DIR/commands/dev.md" "$TARGET_DIR/commands/dev.md"`
  - 변경 후: `copy_file "$PACKAGE_DIR/commands/dev-bounce.md" "$TARGET_DIR/commands/dev-bounce.md"`
  - 완료 메시지(line 339): `commands: dev.md (/dev)` → `commands: dev-bounce.md (/dev-bounce)`

### 기능 4: install.sh CLAUDE.md 자동 주입

- 설명: 설치 시 SCOPE(global/local)에 따라 대상 CLAUDE.md에 `/dev-bounce` 강제 호출 규칙을 관리 블록으로 주입
- 핵심 요구사항:
  - 주입 대상:
    - global 설치 → `~/.claude/CLAUDE.md`
    - local 설치 → `<REPO_ROOT>/.claude/CLAUDE.md`
  - 관리 블록 마커: `# --- ai-bouncer-rule start ---` / `# --- ai-bouncer-rule end ---`
  - 주입 내용:
    ```
    # --- ai-bouncer-rule start ---
    ## ai-bouncer
    코드 수정 / 기능 구현 / 파일 변경 / 버그 수정 등 개발 작업 시 반드시 `/dev-bounce` 스킬을 먼저 호출할 것.
    # --- ai-bouncer-rule end ---
    ```
  - 이미 블록이 있으면 내용 교체 (중복 추가 방지)
  - CLAUDE.md가 없으면 신규 생성
  - 주입 위치: "파일 설치" 섹션 이후, "settings.json 설정" 섹션 이전

### 기능 5: commands/dev-bounce.md — Q&A 및 계획 제시 시 plan mode 활용

- 설명: Phase 1 진입 시점부터 plan mode를 켜고, 사용자에게 질문하거나 계획을 보여줄 때 plan mode UI를 통해 진행
- 핵심 요구사항:
  - Phase 1 진입 직후 `EnterPlanMode` 호출 (플래닝 전체를 plan mode 안에서 진행)
  - Q&A 루프 중 사용자 질문도 plan mode 안에서 수행
  - planner-lead가 plan.md 작성 완료(streak=3) 후 `ExitPlanMode` 호출 → 승인 요청
  - 사용자가 수정 요청 → `EnterPlanMode` 재진입 → planner-lead 재작업 → `ExitPlanMode`
  - 사용자 승인 → Phase 2 진행

### 기능 6: install.sh — 커밋 전략 설정

- 설명: 설치 시 사용자에게 Step 완료 시 커밋 전략을 물어보고 `config.json`에 저장. 나중에 재설정도 가능.
- 핵심 요구사항:
  - 설치 시 커밋 전략 선택:
    ```
    커밋 전략:
      1) per-step   — Step 완료마다 즉시 커밋 + 푸시 (기본값)
      2) per-phase  — 개발 Phase 전체 완료 시 커밋 + 푸시
      3) none       — 커밋하지 않음 (수동 관리)
    ```
  - 커밋 스킬 감지: `~/.claude/commands/commit.md` 또는 `.claude/commands/commit.md` 존재 여부 확인
    - 존재하면 → `commit_skill: true`, 커밋 시 해당 스킬 활용
    - 없으면 → `commit_skill: false`, 일반 `git commit` 사용
  - `config.json`에 저장:
    ```json
    {
      "commit_strategy": "per-step",
      "commit_skill": true
    }
    ```
  - 재설정: `bash install.sh --config` 플래그로 커밋 전략만 다시 선택 가능

### 기능 7: commands/dev-bounce.md — Step 완료마다 커밋 (전략 반영)

- 설명: Phase 3 `[STEP:N:테스트통과]` 직후 `config.json`의 커밋 전략을 읽어 처리
- 핵심 요구사항:
  - `~/.claude/ai-bouncer/config.json` 읽어 `commit_strategy` 확인
  - `commit_strategy: "per-step"`:
    - `commit_skill: true` → `/commit` 스킬 호출
    - `commit_skill: false` → `git add` + `git commit -m "feat: <step 제목> (phase-N step-M)"` + `git push`
  - `commit_strategy: "per-phase"`:
    - 개발 Phase의 마지막 Step `[STEP:N:테스트통과]` 직후에만 커밋 + 푸시
    - `commit_skill: true` → `/commit` 스킬 호출
    - `commit_skill: false` → 일반 `git commit`
  - `commit_strategy: "none"` → 커밋 스킵
  - 커밋 실패 시 다음 Step 진행 금지

### 기능 6: uninstall 시 CLAUDE.md 블록 제거

- 설명: `--uninstall` 실행 시 CLAUDE.md에서 ai-bouncer-rule 관리 블록 제거
- 핵심 요구사항:
  - settings.json hook 제거 로직 직후에 CLAUDE.md 블록 제거 로직 추가
  - 블록이 없으면 no-op (에러 없이 통과)
  - CLAUDE.md가 블록만 포함한 경우에도 파일 자체는 삭제하지 않음

---

## Q&A 요약

| 질문 | 답변 |
|---|---|
| (3회 연속 질문 없음 — 요청 자명) | — |

---

## 기술 고려사항

- 파일명 변경은 `git mv`보다 실제 파일 rename이 적합 (install.sh가 git과 무관하게 파일 복사 방식으로 동작)
- CLAUDE.md 주입은 install_hook의 관리 블록 패턴(start/end 마커 + python3 인라인 스크립트)과 동일한 방식 적용
- `TARGET_DIR`은 이미 SCOPE 결정 시 설정되므로 CLAUDE.md 경로는 `$TARGET_DIR/CLAUDE.md`로 단순화 가능
- uninstall 시 CLAUDE.md 경로 감지: manifest.json에서 TARGET_DIR을 알 수 없으므로 global (`~/.claude/CLAUDE.md`)만 대상으로 하거나, config.json에 scope를 저장하는 방식 필요
  - 권장: install 시 config.json에 `"scope": "global"` 또는 `"local"` + `"target_dir"` 저장 → uninstall에서 참조
- 복잡도: 전체 낮음~중간

---

## QA 고려사항

- 테스트 시나리오:
  1. global 설치 후 `~/.claude/CLAUDE.md`에 블록 존재 확인
  2. local 설치 후 `.claude/CLAUDE.md`에 블록 존재 확인
  3. 재설치(업데이트) 시 블록 중복 없이 교체됨 확인
  4. uninstall 후 CLAUDE.md에서 블록 제거 확인
  5. `commands/dev-bounce.md`가 올바른 경로에 복사됨 확인
  6. `/dev-bounce` 커맨드가 Claude 슬래시 커맨드로 인식되는지 확인 (파일명 기반)
- 엣지 케이스:
  - CLAUDE.md가 없는 환경 → 신규 생성 후 블록 주입
  - CLAUDE.md가 있지만 블록이 없는 환경 → 파일 끝에 append
  - CLAUDE.md 블록만 있는 경우 uninstall → 빈 파일 또는 블록만 제거된 파일 남김 (파일 삭제 안 함)
- 품질 리스크:
  - uninstall 시 TARGET_DIR 경로 불일치 → config.json에 scope/target_dir 저장으로 해소
