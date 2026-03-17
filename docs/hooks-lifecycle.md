# ai-bouncer Hook Lifecycle

Claude Code 생명주기에서 각 훅이 언제, 무엇을 하는지 정리한 다이어그램.

---

## 훅 목록

### 🔴 PreToolUse — `plan-gate` (Edit/Write) · `bash-gate` (Bash)

Claude가 계획 없이 멋대로 코드 짜는 걸 막기 위해 도구 실행 전에 검사.

| 검사 항목 | 이유 |
|---|---|
| 계획을 세우고 승인받았어? | 계획도 없이 코드 바꾸면 안 되니까 |
| TC(테스트 기준)가 작성됐어? | 테스트 기준도 없이 구현하면 안 되니까 |
| 이전 step 테스트 통과했어? | 망가진 상태에서 다음 단계 가면 안 되니까 |
| 팀이 구성됐어? _(NORMAL 모드)_ | 에이전트 없이 개발 단계 진입하면 안 되니까 |
| 테스트 미통과인데 커밋? _(Bash만)_ | 안 되는 코드 커밋하면 안 되니까 |

### 🟡 PostToolUse — `doc-reminder` (Edit/Write) · `bash-audit` (Bash)

도구 실행 후 결과를 검증.

| 검사 항목 | 이유 |
|---|---|
| step 문서가 존재해? _(Edit/Write)_ | 문서 없이 코드만 바꾸면 추적이 안 되니까 |
| 몰래 파일 바꿨어? _(Bash)_ → 자동 되돌림 | PreToolUse를 우회하는 걸 막기 위해 2중으로 감시 |

### 🔵 SubagentStart / SubagentStop — `subagent-track` · `subagent-cleanup`

| 시점 | 하는 일 | 이유 |
|---|---|---|
| 서브 에이전트 시작 | 위 검사 생략 처리 | Main이 이미 통과했으니 서브가 또 막힐 필요 없으니까 |
| 서브 에이전트 종료 | 생략 처리 해제 | 다른 에이전트가 면제를 재사용하지 못하게 |

### 🟠 Stop — `completion-gate` · `stop-active-cleanup` · `stop-bouncer-compat`

응답 턴을 끝내기 전에 실행.

| 검사 항목 | 이유 |
|---|---|
| 검증 3회 연속 통과했어? | 덜 된 상태로 작업 종료하는 걸 막기 위해 |
| 작업 완료 시 잠금 파일 자동 삭제 | 완료 후 다음 작업이 잠겨있으면 안 되니까 |
| 팀 작업 중엔 미커밋 경고 무시 | 팀 작업은 에이전트가 나눠서 커밋하므로 오탐 방지 |

---

## 생명주기 흐름도

```mermaid
sequenceDiagram
    actor U as 👤 User
    participant C as 🤖 Claude
    participant PRE as 🔴 도구 쓰기 전
    participant T as 🛠 Tool
    participant POST as 🟡 도구 쓴 후
    participant SUB as 🔵 서브 에이전트
    participant STP as 🟠 응답 종료 전

    U->>C: 메시지 전송

    rect rgb(255, 220, 220)
        note over PRE: 파일 수정 전: 계획 없음·TC 없음·이전 step 실패·팀 없음 → 차단<br/>커밋 전: 테스트 미통과 상태에서 커밋 시도 → 차단
        C->>PRE: 검사
        PRE-->>C: ⛔ 차단 or ✅ 통과
    end

    C->>T: 도구 실행
    T-->>C: 완료

    rect rgb(255, 255, 200)
        note over POST: 파일 수정 후: step 문서 없이 코드 수정 → 차단<br/>터미널 명령 후: 몰래 파일 바꾸면 → 자동 되돌림
        C->>POST: 검사
        POST-->>C: ⛔ 차단 or 🔄 자동 복원
    end

    opt 서브 에이전트 쓸 때
        rect rgb(210, 230, 255)
            note over SUB: Main이 이미 통과했으므로 서브는 검사 생략<br/>종료되면 원래대로 복귀
            C->>SUB: 스폰
            SUB-->>C: 종료
        end
    end

    rect rgb(255, 230, 200)
        note over STP: 검증 3회 통과 전 → 응답 종료 차단<br/>작업 완료 시 잠금 파일 자동 삭제<br/>팀 작업 중엔 미커밋 경고 무시
        C->>STP: 종료 시도
        STP-->>C: ⛔ 차단 or ✅ 통과
    end

    C-->>U: 응답
```

---

## Block 조건 요약

### 🔴 plan-gate / bash-gate (PreToolUse)

| 조건 | phase | 모드 |
|---|---|---|
| `workflow_phase` 알 수 없는 값 | any | any |
| state.json을 `done`/`verification`으로 직접 변경 | planning | any |
| `plan_approved != true` | development / verification | any |
| `plan.md` 없음 | development / verification | any |
| `team_name` 비어있음 | development | normal · team |
| 팀 config.json 없음 | development | normal · team |
| 팀 멤버 수 < 1 | development | normal · team |
| `dev_phases` 비어있음 | development | normal |
| `current_dev_phase <= 0` or `current_step <= 0` | development | normal |
| 이전 Phase 미완료 (step에 ✅ 없음) | development | normal |
| `phase.md` 없음 | development | normal |
| `phase.md` 필수 섹션 누락 (`## 목표` / `## 범위` / `## Steps`) | development | normal |
| 이전 step-N.md 없음 | development | normal |
| 이전 step-N.md에 ✅ 없음 | development | normal |
| 이전 step-N.md에 실행출력 없음 | development | normal |
| 현재 step-N.md 없음 | development | normal |
| 현재 step-N.md에 TC 행 없음 | development | normal |
| 미완료 Phase 존재 (step에 ✅ 없음) | verification | normal |

**bash-gate 추가 조건 (git commit/push 시):**

| 조건 | commit_strategy |
|---|---|
| `commit_strategy=none` | none |
| `workflow_phase=planning` 중 커밋 | any |
| verification + 미완료 Phase | any |
| 현재 step ✅ 없음 | per-step |
| 마지막 step ✅ 없음 | per-phase |

### 🟡 doc-reminder (PostToolUse)

| 조건 | phase |
|---|---|
| step의 `doc_path` 문서 파일이 없음 | development |

### 🟡 bash-audit (PostToolUse)

Block 없음. bash-gate 스냅샷 대비 무단 변경 파일을 **자동 복원**:
- tracked 파일 → `git checkout` 복원
- untracked 파일 → `rm` 삭제

### 🟠 completion-gate (Stop)

| 조건 | 모드 |
|---|---|
| `plan_approved=true` + phase가 done/cancelled 아님 | simple |
| `plan_approved=true` + development + 진행 중 Phase 있음 | normal |
| verification + `round-*.md` < 3개 | normal |
| verification + 마지막 3 round 연속 통과 < 3 | normal |

> round 통과 조건: `통과` 포함 + `실패` 미포함 + `## 결론` 섹션 존재

---

## 색깔 범례

| 색깔 | 의미 |
|---|---|
| 🔴 빨강 (Pre) | 아예 실행 못 하게 막음 |
| 🟡 노랑 (Post) | 실행은 됐지만 결과를 되돌림 |
| 🔵 파랑 (Sub) | gate 면제권 부여/회수 |
| 🟠 주황 (Stop) | 턴 자체를 못 끝내게 막음 |
