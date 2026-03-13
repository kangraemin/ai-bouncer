# README.md 현행화 — 코드 기준으로 정정

## 변경 파일별 상세

### `README.md`

#### 1. SIMPLE Mode — TC skip 제거 (line 81)
- **변경 이유**: 커밋 7111c47에서 TC 필수로 변경. README는 `[TC:skip] if not` 유지 중
- **Before**:
```
2. **TC + Develop** — Write test cases in `tests.md` if applicable (`[TC:skip]` if not), then implement
```
- **After**:
```
2. **TC + Develop** — Write test cases in `tests.md` (mandatory), then implement
```

#### 2. SIMPLE Mode — TC 흐름 보강 (line 80-82)
- **변경 이유**: TC 작성 → 개발 → 실행출력 기록 흐름이 빠져있음
- **Before**:
```
1. **Plan** — Explore code, write `plan.md` with Before/After code snippets, get approval
2. **TC + Develop** — Write test cases in `tests.md` if applicable (`[TC:skip]` if not), then implement
3. **Verify** — Run tests, lightweight plan-vs-diff check, done
```
- **After**:
```
1. **Plan** — Explore code, write `plan.md` with Before/After snippets, get approval
2. **TC + Develop** — Write test cases in `tests.md` (table + execution output format, mandatory), implement, record actual results as evidence
3. **Verify** — Run tests, lightweight plan-vs-diff check, done
```

#### 3. NORMAL Mode — agent_mode별 동작 설명 추가
- **변경 이유**: Installation Options에 team/subagent/single 옵션이 있는데 NORMAL 섹션은 team 기준으로만 설명
- Phase 3 설명에 agent_mode별 차이 추가

#### 4. TC 포맷 변경 반영
- **변경 이유**: TC가 테이블+실행출력 증거 형식으로 바뀜
- step-M.md 설명에 "TC table + execution output evidence" 추가

## 검증
- `grep -n "TC:skip\|TC skip" README.md` → 0 matches
- `grep -n "single" README.md` → agent_mode 설명 존재 확인
- `grep -n "execution output" README.md` → TC 포맷 언급 확인
