---
description: 에이전트 팀으로 개발 시작
---

# /dev

개발 작업의 규모를 판별하고, 적절한 방식으로 진행한다.

---

## 사전 확인

`$ARGUMENTS`가 비어있거나 작업 내용이 불충분하면, **반드시 사용자에게 무엇을 구현할지 되물어본다.** 충분한 정보를 얻은 후 진행한다.

## 규모 판별

요청 내용을 분석하여 규모를 판별한다.

### 소규모 (Solo)
- 파일 1~3개 수정
- 단일 기능 추가/수정/버그 수정
- 아키텍처 변경 없음
- 예: 버튼 추가, API 엔드포인트 하나 수정, 설정값 변경

→ **메인 에이전트가 직접 구현.** 팀 생성 안 함.

### 중규모 (Duo)
- 파일 4~10개 수정
- 여러 레이어에 걸치지만 범위가 명확
- 예: 새 화면 하나 추가, 기존 기능에 옵션 추가

→ **Dev 1명만 스폰.** 메인 에이전트가 Lead 역할 겸임.

### 대규모 (Team)
- 파일 10개 이상 또는 새 모듈/피처
- 아키텍처 변경 포함
- 여러 Phase가 필요할 수 있음
- 예: 새 프로젝트, 대규모 리팩토링, 복합 피처

→ **풀 팀 구성** (Lead + Dev + QA).

**판별이 애매하면 사용자에게 확인한다.**

---

## 모델 배정

| 에이전트 | 모델 | 용도 |
|---------|------|------|
| Lead | opus | 설계, 태스크 분해, 품질 판단 |
| Dev | sonnet | 코드 구현 |
| QA | sonnet | 테스트/빌드 검증 |

Task 도구로 에이전트 스폰 시 반드시 `model` 파라미터를 지정한다.

---

## 모드 판별 (중규모/대규모에서만)

프로젝트 루트에 `DEVELOPMENT_GUIDE.md`가 있는지 확인한다.

- **없음** → **신규 모드**: 프로젝트 초기 설정부터 시작
- **있음** → **피처 모드**: 사용자 지시를 피처 태스크로 바로 진행

---

## 소규모 (Solo) 진행

1. 프로젝트에 `DEVELOPMENT_GUIDE.md`가 있으면 읽고 컨벤션을 따른다.
2. 직접 구현한다.
3. 빌드/테스트 검증한다.
4. 커밋 + 푸시 (로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md` 준수).

---

## 중규모 (Duo) 진행

### Step 1: Dev 스폰

Dev 에이전트를 **sonnet 모델**로 스폰한다 (`~/.claude/agents/dev.md`).

메인 에이전트가 Lead 역할:
- 구현 계획을 사용자에게 승인받는다.
- Dev에게 태스크를 전달한다.
- Dev 완료 후 직접 빌드/테스트를 검증한다.

### Step 2: 개발 루프

```
메인(Lead): 계획 → 사용자 승인 → 태스크 전달
  ↓
Dev(sonnet): 구현 → 완료 보고
  ↓
메인(Lead): 빌드/테스트 검증 → 완료 또는 수정 요청
```

---

## 대규모 (Team) — 신규 모드 (DEVELOPMENT_GUIDE.md 없음)

### Step 1: 프로젝트 초기화

`/init-project` 플로우를 먼저 실행한다 (대화하며 가이드 생성). 완료 후 Step 2로 진행.

### Step 2: 팀 생성

TeamCreate로 팀을 생성한다.

```
team_name: "<프로젝트명>-dev"
```

### Step 3: Lead 스폰

Lead 에이전트를 **opus 모델**로 스폰한다 (`~/.claude/agents/lead.md`).

Lead에게 전달할 지시:
- `DEVELOPMENT_GUIDE.md`와 참조 문서들을 읽어라.
- `docs/PHASES.md`가 없으면: 전체 Phase 계획을 설계하고, 사용자에게 승인을 요청하라.
- `docs/PHASES.md`가 있으면: 현재 Phase에서 미완료 Step을 확인하고 이어서 진행하라.
- 사용자 승인 후 현재 Phase의 Step을 TaskCreate로 생성하라.

### Step 4: Dev / QA 스폰

Lead가 태스크를 생성하면 에이전트를 스폰한다.

- **Dev** (`~/.claude/agents/dev.md`): **sonnet 모델**, 구현 담당
- **QA** (`~/.claude/agents/qa.md`): **sonnet 모델**, 테스트/검증 담당

### Step 5: 개발 루프

```
Lead(opus): Phase 설계 → 사용자 승인 → 태스크 생성/배정
  ↓
Dev(sonnet): 태스크 구현 → 완료 보고
  ↓
QA(sonnet): 테스트/빌드 검증 → 통과/반려
  ↓
Lead(opus): Step 완료 확인 → PHASES.md 업데이트
  ↓
(다음 Step 또는 다음 Phase)
```

---

## 대규모 (Team) — 피처 모드 (DEVELOPMENT_GUIDE.md 있음)

### Step 1: 팀 생성

TeamCreate로 팀을 생성한다.

```
team_name: "<프로젝트명>-dev"
```

### Step 2: Lead 스폰

Lead 에이전트를 **opus 모델**로 스폰한다 (`~/.claude/agents/lead.md`).

Lead에게 전달할 지시:
- `DEVELOPMENT_GUIDE.md`와 참조 문서들을 읽어라.
- **피처 모드**로 동작하라.
- 사용자의 요청 내용: `$ARGUMENTS`
- 기존 코드베이스를 분석하고, 요청을 Step 단위 태스크로 분해하라.
- 사용자에게 구현 계획을 승인받은 후 TaskCreate로 생성하라.

### Step 3: Dev / QA 스폰

Lead가 태스크를 생성하면 에이전트를 스폰한다.

- **Dev** (`~/.claude/agents/dev.md`): **sonnet 모델**, 구현 담당
- **QA** (`~/.claude/agents/qa.md`): **sonnet 모델**, 테스트/검증 담당

### Step 4: 개발 루프

```
Lead(opus): 피처 분석 → 구현 계획 → 사용자 승인 → 태스크 생성/배정
  ↓
Dev(sonnet): 태스크 구현 → 완료 보고
  ↓
QA(sonnet): 테스트/빌드 검증 → 통과/반려
  ↓
Lead(opus): Step 완료 확인 → 다음 태스크 진행
```

---

## 주의사항

- 구현 계획은 **반드시 사용자 승인** 후 진행한다.
- 신규 모드: 한 번에 하나의 Phase만 진행. Phase 완료 시 다음 Phase 진행 여부 확인.
- 피처 모드: PHASES.md 생성/수정하지 않음. 피처 완료 시 사용자에게 보고.
- 커밋은 로컬 `.claude/rules/git-rules.md` 우선, 없으면 `~/.claude/rules/git-rules.md` 규칙을 따른다.
- 규모 판별이 틀렸다고 느끼면 (작업 도중 예상보다 커지면) 사용자에게 알리고 팀 확장 여부를 확인한다.
