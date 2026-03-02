# 검증 3회차

독립 검증. 이전 라운드 컨텍스트 의존 없음.

---

## 통합 정합성 집중 검증 (Round 3 초점)

### IC-1: install.sh copy_file "dev-bounce.md" AND commands/dev-bounce.md 실존 여부

**검증 항목**: install.sh가 `dev-bounce.md`를 복사하는 경로와 실제 소스 파일의 존재가 end-to-end 일치하는가.

```
install.sh line 309:
  copy_file "$PACKAGE_DIR/commands/dev-bounce.md"  "$TARGET_DIR/commands/dev-bounce.md"

파일 존재:
  /commands/dev-bounce.md — 존재 (7301 bytes, 2026-03-03)
```

결론: install.sh의 복사 소스 `$PACKAGE_DIR/commands/dev-bounce.md`와 실제 파일 `commands/dev-bounce.md`가 정확히 일치. end-to-end 정합. ✅

---

### IC-2: install.sh CLAUDE.md 주입 마커 vs uninstall 제거 마커 일치

**검증 항목**: 주입 섹션과 제거 섹션이 동일한 마커 문자열을 사용하는가.

```
[주입 섹션 — install.sh line 381-382]
START = "# --- ai-bouncer-rule start ---"
END   = "# --- ai-bouncer-rule end ---"

[주입 block 리터럴 — install.sh line 385-388]
# --- ai-bouncer-rule start ---
## ai-bouncer
코드 수정 / 기능 구현 / 파일 변경 / 버그 수정 등 개발 작업 시 반드시 `/dev-bounce` 스킬을 먼저 호출할 것.
# --- ai-bouncer-rule end ---

[제거 섹션 — install.sh line 108-109]
START = "# --- ai-bouncer-rule start ---"
END   = "# --- ai-bouncer-rule end ---"
```

결론: 주입 시 사용하는 START/END 마커("ai-bouncer-rule start" / "ai-bouncer-rule end")와 uninstall 제거 섹션이 사용하는 마커가 문자열 수준에서 완전 동일. 마커 불일치로 인한 제거 실패 가능성 없음. ✅

---

### IC-3: config.json 키 정합성 (install 저장 ↔ --config 읽기 ↔ dev-bounce.md 참조)

**검증 항목**: install이 저장하는 키와 --config가 읽는 키, dev-bounce.md가 참조하는 키가 모두 일치하는가.

```
[install.sh — config.json 저장 (line 362-367)]
{
  "docs_git_track": $DOCS_TRACK_BOOL,
  "commit_strategy": "$COMMIT_STRATEGY",
  "commit_skill": $COMMIT_SKILL_BOOL,
  "target_dir": "$TARGET_DIR"
}

[install.sh --config 모드 — 읽기/쓰기 (line 174-182)]
cfg["commit_strategy"] = strategy
cfg["commit_skill"] = skill
→ commit_strategy, commit_skill 두 키 업데이트 (target_dir, docs_git_track은 보존)

[dev-bounce.md — 참조 (line 200)]
cfg.get('commit_strategy','per-step'), cfg.get('commit_skill', False)

[plan.md 기능 6 요구사항]
"commit_strategy": "per-step",
"commit_skill": true

[plan.md 기능 7 요구사항]
~/.claude/ai-bouncer/config.json 읽어 commit_strategy 확인
commit_skill: true → /commit 스킬 호출
commit_skill: false → 일반 git commit
```

결론:
- install이 저장하는 4개 키: `docs_git_track`, `commit_strategy`, `commit_skill`, `target_dir`
- --config가 업데이트하는 키: `commit_strategy`, `commit_skill` (나머지 보존 — 정합)
- dev-bounce.md가 읽는 키: `commit_strategy`, `commit_skill` — install 저장 키와 일치
- plan.md 요구사항과 일치

모든 레이어 정합. ✅

---

### IC-4: dev-bounce.md Phase 1 섹션 번호 정합성

**검증 항목**: 1-0 → 1-1 → 1-2 → 1-3 → 1-4 → 1-5 → Phase 2 재진입 흐름이 논리적으로 일관되는가.

```
### 1-0. Plan Mode 진입          (line 39)  — EnterPlanMode 호출
### 1-1. TASK_DIR 초기화         (line 43)  — TASK_DIR 설정, state.json 초기화
### 1-2. Planning Team 구성      (line 75)  — TeamCreate: planner-lead, planner-dev, planner-qa
### 1-3. Q&A 루프               (line 86)  — 질문 생성 → 사용자 답변 → streak 관리
### 1-4. 계획 확정               (line 103) — plan.md 생성, Planning 팀 shutdown
### 1-5. 계획 사용자에게 표시     (line 109) — plan.md 표시 + ExitPlanMode 호출
```

흐름 검증:
- 1-0: EnterPlanMode → plan mode 진입 (Planning 전체를 plan mode 안에서 진행) ✅
- 1-1: TASK_DIR 및 state.json 초기화 (plan mode 안에서 수행) ✅
- 1-2: Planning Team 구성 (plan mode 안에서 수행) ✅
- 1-3: Q&A 루프 (plan mode 안에서 수행, streak=3 되면 다음 단계) ✅
- 1-4: 계획 확정 → plan.md 생성 → Planning 팀 shutdown ✅
- 1-5: plan.md 표시 → ExitPlanMode → 사용자 승인 요청 ✅

Phase 2 재진입: "수정 요청 시: EnterPlanMode 재진입 → planner-lead에게 재작업 지시 → 1-3 Q&A 루프 재시작" (line 129)

논리 흐름: plan mode 진입(1-0) → 초기화(1-1) → 팀(1-2) → Q&A(1-3) → 확정(1-4) → 표시+ExitPlanMode(1-5) → Phase 2. 순서 완전 일치, 빠진 단계 없음. ✅

---

### IC-5: dev-bounce.md Phase 3 섹션 번호 정합성 (재번호 후)

**검증 항목**: 3-4 커밋 → 3-5 블로킹 → 3-6 완료 순서가 논리적으로 일관되는가.

```
### 3-1. Lead 에이전트 스폰       (line 150) — TASK_DIR 전달, 팀 규모 판단
### 3-2. 팀 구성                  (line 160) — solo/duo/team 분기
### 3-3. TDD 개발 루프            (line 168) — Step마다 TC→Dev→QA 반복
### 3-4. Step/Phase 완료 시 커밋  (line 192) — config.json 커밋 전략 읽기
### 3-5. 블로킹 에스컬레이션      (line 214) — 기술불가/기획질문 처리
### 3-6. 모든 Step 완료           (line 226) — [ALL_STEPS:완료] → Phase 4 진행
```

흐름 검증:
- 3-3 TDD 루프에서 `[STEP:N:테스트통과]` 발생 → 3-4 커밋 처리 ✅
- 3-3 TDD 루프에서 구현 불가 → 3-5 블로킹 에스컬레이션 ✅
- 3-3의 모든 Step 완료 후 → 3-6에서 `[ALL_STEPS:완료]` → Phase 4 ✅
- 3-4 커밋 실패 → "다음 Step 진행 금지" (3-3으로 재시도) ✅

순서: 3-4 커밋 → 3-5 블로킹 → 3-6 완료 정합. 재번호 이후 빠진 번호 없음. ✅

---

### IC-6: bash -n install.sh

```
실행: bash -n install.sh
결과: (출력 없음)
EXIT_CODE: 0
```

결론: bash 문법 오류 없음. ✅

---

## Plan 대비 구현 확인

- 기능 1 (commands/dev.md → dev-bounce.md rename): ✅ 파일 존재 확인, dev.md 없음
- 기능 2 (파일 내 커맨드명 변경): ✅ Line 5 `# /dev-bounce`, frontmatter description `/dev-bounce`
- 기능 3 (install.sh copy_file 경로 변경): ✅ line 309 dev-bounce.md, 완료 메시지 line 490 `/dev-bounce`
- 기능 4 (CLAUDE.md 관리 블록 주입): ✅ ai-bouncer-rule start/end 마커, 3분기 처리
- 기능 5 (Plan mode 흐름): ✅ 1-0 EnterPlanMode(line 41), 1-5 ExitPlanMode(line 121), 재진입(line 129)
- 기능 6 (커밋 전략 설정 + --config): ✅ per-step/per-phase/none UI, config.json 4개 키 저장, --config exit 0
- 기능 7 (dev-bounce.md 커밋 전략 처리): ✅ 3-4 섹션 commit_strategy/commit_skill 읽기+처리 표
- 기능 6b (uninstall CLAUDE.md 블록 제거): ✅ ai-bouncer-rule 동일 마커로 제거, no-op, 파일 보존

---

## 통합 정합성 체크리스트

| 항목 | 설명 | 결과 |
|---|---|---|
| IC-1 | install.sh dev-bounce.md 복사 ↔ commands/dev-bounce.md 실존 | ✅ |
| IC-2 | 주입 마커 = 제거 마커 ("ai-bouncer-rule start/end") | ✅ |
| IC-3 | config.json 키 4개 저장 ↔ --config 2개 업데이트 ↔ dev-bounce.md 2개 참조 정합 | ✅ |
| IC-4 | Phase 1: 1-0→1-1→1-2→1-3→1-4→1-5→Phase 2 순서 정합 | ✅ |
| IC-5 | Phase 3: 3-4 커밋→3-5 블로킹→3-6 완료 순서 정합 | ✅ |
| IC-6 | bash -n install.sh: EXIT_CODE 0 (문법 오류 없음) | ✅ |

---

## 결론

통과. 6개 통합 정합성 항목 전부 실제 파일 검증으로 확인. 이전 라운드와 독립적으로 수행.
