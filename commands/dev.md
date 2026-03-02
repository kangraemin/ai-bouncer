---
description: 에이전트 팀으로 개발 시작 (plan-gate 적용)
---

# /dev

구조화된 개발 flow를 실행한다. 계획 승인 없이는 코드를 수정하지 않는다.

---

## Phase 0: 인텐트 판별

요청이 **코드 변경을 수반하는 개발 작업**인지 먼저 판별한다.

**비개발 요청** → 일반 응답으로 처리, /dev flow 시작 안 함:
- "조사해", "알아봐", "찾아봐", "분석해", "설명해", "어떻게 생각해", "계획만"

**개발 요청이지만 내용 불충분** → "무엇을 구현할까요?" 되물음

**개발 요청 + 내용 충분** → Phase 1 시작

---

## Phase 1: 계획 수립

1. 관련 파일/코드 탐색 및 분석
2. **Step 단위로 쪼개기**
   - 한 Step = 1커밋으로 완결되는 최소 단위
   - "A하고 B한다" 형태면 무조건 분리
   - 각 Step마다 완료 기준 명시 (어떤 테스트가 통과해야 하는가)
3. 아래 형식으로 출력:

```
[PLAN:승인대기]

## 구현 계획

### Step 1: <제목>
- 작업: <파일명 + 무엇을>
- 완료 기준: <어떤 테스트가 통과해야 하는가>

### Step 2: <제목>
- 작업: ...
- 완료 기준: ...

총 N개 Step. 수정 요청이 있으면 말씀해주세요. 승인하시면 시작합니다.
```

---

## Phase 2: 계획 논의

사용자 피드백 대기. 수정 요청이 있으면 계획 업데이트 후 `[PLAN:승인대기]` 다시 출력.

**승인 신호 감지**: "승인", "시작", "ㄱㄱ", "ㅇㅇ", "진행", "go", "ok"
→ Phase 3으로 진행

---

## Phase 3: 승인 처리

승인 신호 감지 시 즉시 state.json 업데이트:

```bash
python3 << 'PYEOF'
import json, os
f = os.path.expanduser('~/.claude/ai-bouncer/state.json')
with open(f) as fp:
    s = json.load(fp)
s['plan_approved'] = True
s['current_step'] = 1
# TOTAL_STEPS를 실제 Step 수로 교체할 것
TOTAL_STEPS = 3
s['steps'] = {str(i): {'test_defined': False, 'passed': False} for i in range(1, TOTAL_STEPS + 1)}
with open(f, 'w') as fp:
    json.dump(s, fp, indent=2)
print('plan_approved = true, steps initialized')
PYEOF
```

`[PLAN:승인됨]` 출력 후 규모 판별 → Phase 4

---

## Phase 4: 규모 판별 및 팀 구성

### 모델 배정

| 에이전트 | 모델 | 용도 |
|---------|------|------|
| Lead | opus | 설계, 태스크 분해, 품질 판단 |
| Dev | sonnet | 코드 구현 |
| QA | sonnet | 테스트/검증 |

### 소규모 (Solo) — 파일 1~3개
→ 메인 에이전트가 직접 Phase 5 진행

### 중규모 (Duo) — 파일 4~10개
→ Dev(sonnet) 1명 스폰, 메인이 Lead 겸임

### 대규모 (Team) — 파일 10개 이상 또는 새 모듈
→ TeamCreate + Lead(opus) + Dev(sonnet) + QA(sonnet) 스폰

**판별 애매하면 사용자에게 확인.**

`DEVELOPMENT_GUIDE.md` 없으면 `/init-project` 먼저 실행.

---

## Phase 5: 개발 루프 (Step N 반복)

각 Step마다 반드시 아래 순서로 진행한다.

### 5-1. 테스트 정의 (QA)

이 Step의 **실패하는 테스트를 먼저 작성**한다.

완료 후 state.json 업데이트:
```bash
python3 << 'PYEOF'
import json, os
f = os.path.expanduser('~/.claude/ai-bouncer/state.json')
with open(f) as fp: s = json.load(fp)
step = str(s['current_step'])
s['steps'][step]['test_defined'] = True
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
print(f'step {step} test_defined = true')
PYEOF
```

`[STEP:N:테스트정의완료]` 출력

### 5-2. 구현 (Dev)

테스트를 통과할 **최소한의 코드만** 작성한다.

완료 보고 형식 — **빌드 결과 없으면 보고 불가**:
```
[STEP:N:개발완료]
빌드 명령: <실행한 명령어>
결과: ✅ 성공
      (또는 ❌ 실패: <에러 내용>)
```

### 5-3. 테스트 실행 (QA)

테스트 실행 후 보고 형식 — **실행 결과 없으면 보고 불가**:
```
[STEP:N:테스트통과]
명령어: <실행한 명령어>
결과: N/N 통과
```

통과 시 state.json 업데이트:
```bash
python3 << 'PYEOF'
import json, os
f = os.path.expanduser('~/.claude/ai-bouncer/state.json')
with open(f) as fp: s = json.load(fp)
step = str(s['current_step'])
s['steps'][step]['passed'] = True
s['current_step'] = s['current_step'] + 1
with open(f, 'w') as fp: json.dump(s, fp, indent=2)
print(f'step {step} passed, current_step -> {s["current_step"]}')
PYEOF
```

실패 시 → Dev에게 반려, 5-2로 돌아감

---

## Phase 6: 회귀 테스트

모든 Step 완료 후 Step 1부터 전체 테스트 재실행.

```
[REGRESSION:통과]
전체 N개 테스트 통과
```

실패 시 → 해당 Step으로 되돌아가기

---

## 주의사항

- `[PLAN:승인됨]` 없이 코드 수정 시도 → plan-gate.sh가 차단
- 이전 Step 테스트 미통과 상태에서 다음 Step 코드 수정 → plan-gate.sh가 차단
- 커밋: 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md`
- Step 완료 = 즉시 커밋 + 푸시
- 규모 판별이 틀리면 사용자에게 알리고 팀 확장 여부 확인
