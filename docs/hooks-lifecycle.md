# ai-bouncer Hook Lifecycle

Claude Code 생명주기에서 각 훅이 언제, 무엇을 하는지 정리한 다이어그램.

---

## 훅 목록

| Hook | 이벤트 | 대상 도구 | 역할 |
|---|---|---|---|
| `plan-gate` | PreToolUse | Write / Edit / MultiEdit | 파일 쓰기 전 워크플로우 검증 |
| `bash-gate` | PreToolUse | Bash | 파일 쓰기 패턴 + 커밋 검증 |
| `doc-reminder` | PostToolUse | Write / Edit / MultiEdit | 코드 수정 후 step 문서 존재 검증 |
| `bash-audit` | PostToolUse | Bash | bash-gate 우회 시 파일 강제 복원 |
| `subagent-track` | SubagentStart | — | sub-agent session_id 승인 목록 등록 |
| `subagent-cleanup` | SubagentStop | — | sub-agent 종료 시 승인 목록 제거 |
| `completion-gate` | Stop | — | 응답 턴 종료 전 워크플로우 완료 검증 |
| `stop-active-cleanup` | Stop | — | done 상태 `.active` 자동 삭제 |
| `stop-bouncer-compat` | Stop | — | NORMAL 팀 작업 중 미커밋 체크 스킵 |

---

## 생명주기 흐름도

```mermaid
sequenceDiagram
    actor U as 👤 User
    participant C as 🤖 Claude
    participant PRE as 🔴 PreToolUse
    participant T as 🛠 Tool
    participant POST as 🟡 PostToolUse
    participant SUB as 🔵 Sub-agent
    participant STP as 🟠 Stop

    U->>C: 메시지 전송

    rect rgb(255, 220, 220)
        note over PRE: plan-gate: 계획 없음·TC 없음·이전 step 실패·팀 없음 → Write/Edit 차단<br/>bash-gate: 위 동일 + 미완료 상태에서 커밋 시도 → Bash 차단
        C->>PRE: 도구 실행 전 검증
        PRE-->>C: ⛔ Block or ✅ Pass
    end

    C->>T: 도구 실행
    T-->>C: 완료

    rect rgb(255, 255, 200)
        note over POST: doc-reminder: step 문서 없이 코드 수정 → 차단<br/>bash-audit: gate 우회해서 파일 바꾸면 → 자동 되돌림
        C->>POST: 도구 완료 후 검증
        POST-->>C: ⛔ Block or 🔄 자동 복원
    end

    opt Sub-agent 스폰 시
        rect rgb(210, 230, 255)
            note over SUB: 스폰된 에이전트는 gate 검사 면제, 종료되면 면제권 회수
            C->>SUB: 스폰
            SUB-->>C: 종료
        end
    end

    rect rgb(255, 230, 200)
        note over STP: completion-gate: 검증 3회 통과 전 → 턴 종료 차단<br/>stop-active-cleanup: done 상태 .active 자동 삭제<br/>stop-bouncer-compat: 팀 작업 중 미커밋 경고 스킵
        C->>STP: 응답 종료 시도
        STP-->>C: ⛔ Block or ✅ Pass
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
