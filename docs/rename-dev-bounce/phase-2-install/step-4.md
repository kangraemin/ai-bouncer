# Step 4: dev-bounce.md 커밋 전략 처리 흐름 추가

## 완료 기준

- `commands/dev-bounce.md` Phase 3 TDD 루프 섹션에 `config.json`의 `commit_strategy` 읽는 흐름이 명시됨
- `per-step` 전략: `[STEP:N:테스트통과]` 직후 즉시 커밋 + 푸시 흐름 명시
- `per-phase` 전략: 개발 Phase의 마지막 Step 완료 시에만 커밋 + 푸시 흐름 명시
- `none` 전략: 커밋 스킵 명시
- `commit_skill=true` 시 `/commit` 스킬 호출, `commit_skill=false` 시 `git commit` 명시
- 커밋 실패 시 다음 Step 진행 금지 명시

## 테스트 케이스

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | `commands/dev-bounce.md` Phase 3 섹션에서 `commit_strategy` 키워드 검색 | `commit_strategy` 읽는 로직/설명이 Phase 3 (3-3. TDD 개발 루프 또는 3-5 이후) 섹션 내에 존재 |  |
| TC-2 | `commands/dev-bounce.md`에서 `per-step` 전략 설명 검색 | `[STEP:N:테스트통과]` 직후 즉시 커밋 + 푸시하는 흐름이 문서에 명시되어 있음 |  |
| TC-3 | `commands/dev-bounce.md`에서 `per-phase` 전략 설명 검색 | 개발 Phase의 마지막 Step `[STEP:N:테스트통과]` 직후에만 커밋 + 푸시하는 흐름이 문서에 명시되어 있음 |  |
| TC-4 | `commands/dev-bounce.md`에서 `none` 전략 설명 검색 | `commit_strategy: "none"` 시 커밋을 스킵한다는 내용이 명시되어 있음 |  |
| TC-5 | `commands/dev-bounce.md`에서 `commit_skill` 분기 설명 검색 | `commit_skill=true`이면 `/commit` 스킬 호출, `commit_skill=false`이면 `git commit` 명령 사용한다는 내용이 명시되어 있음 |  |

## 검증 명령어

```bash
# TC-1: commit_strategy 키워드가 Phase 3 섹션에 존재
grep -n "commit_strategy" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md

# TC-2: per-step 전략 흐름 명시
grep -n "per-step" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md

# TC-3: per-phase 전략 흐름 명시
grep -n "per-phase" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md

# TC-4: none 전략 (커밋 스킵) 명시
grep -n "none" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md

# TC-5: commit_skill 분기 명시
grep -n "commit_skill" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md
```

## 구현 내용

- `commands/dev-bounce.md` Phase 3 섹션의 5-3 QA 블록 직후에 `### 3-4. Step/Phase 완료 시 커밋` 섹션 추가
- `config.json`에서 `commit_strategy`, `commit_skill` 읽는 python3 명령어 삽입
- `per-step`, `per-phase`, `none` 전략별 커밋 시점과 방법을 표로 명시
- 커밋 실패 시 다음 Step 진행 금지 규칙 명시
- 기존 `3-4. 블로킹 에스컬레이션` → `3-5`, `3-5. 모든 Step 완료` → `3-6`으로 재번호 부여

## 변경 파일

- `commands/dev-bounce.md`: 3-4 섹션 신규 추가, 기존 3-4/3-5 → 3-5/3-6 재번호

## 빌드

```bash
grep -n "commit_strategy" /Users/ram/programming/vibecoding/ai-bouncer/commands/dev-bounce.md
```
결과: 해당 키워드가 Phase 3 (3-4) 섹션 내 존재 확인 (line 200, 204)

## 구현 참고 (Dev용)

계획(`plan.md` 기능 7) 기준 추가 내용:

```
### 3-5a. Step 완료 커밋 처리

[STEP:N:테스트통과] 직후:

1. `~/.claude/ai-bouncer/config.json` 읽기 → `commit_strategy`, `commit_skill` 확인
2. 전략별 처리:
   - `commit_strategy: "per-step"`:
     - `commit_skill: true` → `/commit` 스킬 호출
     - `commit_skill: false` → `git add` + `git commit -m "feat: <step 제목> (phase-N step-M)"` + `git push`
   - `commit_strategy: "per-phase"`:
     - 현재 Step이 해당 Phase의 마지막 Step인 경우에만 커밋 + 푸시
     - `commit_skill: true` → `/commit` 스킬 호출
     - `commit_skill: false` → 일반 `git commit`
   - `commit_strategy: "none"` → 커밋 스킵
3. 커밋 실패 시 다음 Step 진행 금지
```
