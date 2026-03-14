# SKILL.md 수정: plan 요약 + SIMPLE 커밋 + 복잡도 판별 시점 + docs 구조 명세

## Context

ai-bouncer dev-bounce 스킬의 4가지 문제:
1. ExitPlanMode 요약이 plan.md 대비 부실
2. SIMPLE 모드에 커밋 전략 없음
3. 복잡도 판별이 코드 탐색 전에 이루어져 부정확
4. docs 디렉토리 구조 명세 없어 phase 문서 중복 생성 (flat file + directory 양쪽)

## 변경 파일 (1개)

### `skills/dev-bounce/SKILL.md`

#### 수정 1: Phase 0-B 복잡도 판별 → Plan 작성 후로 이동

- **변경 이유**: 코드를 안 읽고 추측으로 SIMPLE/NORMAL 결정하면 부정확
- **Before**: Phase 0-B에서 바로 SIMPLE/NORMAL 판별 + TASK_DIR 초기화
- **After**:
  - Phase 0-B: TASK_DIR 초기화만 (`mode: "pending"`)
  - 기존 SIMPLE S1 + NORMAL Phase 1 → "Phase 1: 계획 수립"으로 통합 (내용 동일하므로)
  - ExitPlanMode accept 후 "Phase 1-B: 복잡도 판별" 신설: plan.md 읽고 SIMPLE 기준 적용
  - SIMPLE이면 S2, NORMAL이면 Phase 3으로 분기

#### 수정 2: Step 5 plan 요약 품질 강화

- **변경 이유**: "계획 요약 정리"가 모호 → "파일명: 한 줄"만 나열하는 부실 요약
- **Before**: `plan mode 내부 plan 파일에 계획 요약 정리`
- **After**: 파일별 Before/After 핵심, 검증 방법 포함 의무화. 부실 요약 금지 명시.

#### 수정 3: SIMPLE 모드 커밋 전략 섹션 추가

- **변경 이유**: NORMAL 3-4에만 커밋 규칙, SIMPLE에는 전무
- **위치**: Phase S2 끝, S3 앞
- **내용**: config.json `commit_strategy` 기반 커밋. TC 전부 ✅ 후 커밋.

#### 수정 4: docs 디렉토리 구조 명세 추가

- **변경 이유**: 구조 명세 없어서 Lead/Dev가 `phase-1.md`(flat) + `phase-1/phase.md`(dir) 양쪽 생성, `verification/` + `verifications/` 중복
- **위치**: NORMAL 모드 Phase 3 앞 (또는 공통 섹션)
- **Before**: (없음)
- **After** (새 섹션):
```markdown
### docs 디렉토리 구조 (NORMAL 모드)

```
docs/YYYY-MM-DD/task-name/
├── .active                    # 세션 잠금
├── state.json                 # 워크플로우 상태
├── plan.md                    # 승인된 계획
├── tests.md                   # TC (SIMPLE만)
├── phase-1-<이름>/            # 디렉토리 (flat file 금지)
│   ├── phase.md               # 필수: ## 목표, ## 범위, ## Steps
│   ├── step-1.md              # TC + 실행출력
│   └── step-2.md
├── phase-2-<이름>/
│   ├── phase.md
│   └── step-1.md
└── verifications/             # 반드시 복수형
    ├── round-1.md
    ├── round-2.md
    └── round-3.md
```

⚠️ `phase-N.md` (flat 파일) 생성 금지 — 반드시 `phase-N-<이름>/phase.md` 디렉토리 구조 사용.
⚠️ `verification/` (단수형) 생성 금지 — 반드시 `verifications/` (복수형) 사용.
hooks가 디렉토리 구조만 검증하므로 flat 파일은 무시된다.
```

## 검증
- `grep -c "Phase 1-B" skills/dev-bounce/SKILL.md` → 1
- `grep -c "plan.md의 핵심을 반영" skills/dev-bounce/SKILL.md` → 1
- `grep -c "S2 커밋" skills/dev-bounce/SKILL.md` → 1
- `grep -c "flat 파일.*금지" skills/dev-bounce/SKILL.md` → 1
- `git diff` 로 전체 변경 리뷰
