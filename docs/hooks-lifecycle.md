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
flowchart TD
    User([👤 User 입력]) --> Claude[🤖 Claude 응답 생성]
    Claude --> ToolQ{도구 사용?}
    ToolQ -->|No| StopHooks

    ToolQ -->|Yes| ToolType{도구 종류}

    subgraph PRE ["🔴 PreToolUse — 도구 실행 전"]
        direction TB
        ToolType -->|Write / Edit / MultiEdit| PG["plan-gate\n워크플로우 검증\n(plan승인·TC·step 순서 등)"]
        ToolType -->|Bash + 쓰기 패턴 감지| BG["bash-gate\n파일쓰기 + 커밋 검증\n(plan-gate 동일 + commit_strategy)"]
        ToolType -->|그 외| PrePass[✅ 통과]
    end

    PG -->|⛔ Block| BackToClaude[에러 반환 → Claude 재시도]
    BG -->|⛔ Block| BackToClaude
    BackToClaude --> Claude

    PG -->|✅ Pass| ToolRun[🛠 도구 실행]
    BG -->|✅ Pass| ToolRun
    PrePass --> ToolRun

    subgraph POST ["🟡 PostToolUse — 도구 실행 후"]
        direction TB
        ToolRun --> ToolType2{도구 종류}
        ToolType2 -->|Write / Edit 완료| DR["doc-reminder\nstep 문서 존재 검증"]
        ToolType2 -->|Bash 완료| BA["bash-audit\n무단 변경 파일 감지\n→ 자동 복원(checkout/rm)"]
        ToolType2 -->|그 외| PostPass[✅ 통과]
    end

    DR -->|⛔ Block| BackToClaude
    DR -->|✅ Pass| MoreTools{계속 도구 사용?}
    BA -->|🔄 자동 복원 후 계속| MoreTools
    PostPass --> MoreTools

    MoreTools -->|Yes| ToolType

    subgraph SUB ["🔵 SubagentStart / SubagentStop — sub-agent 생명주기"]
        direction LR
        ST["subagent-track\nsession_id 승인 목록 등록\n(plan·bash gate 스킵 허용)"]
        --> SA["🤖 Sub-agent 실행"]
        --> SC["subagent-cleanup\n승인 목록 제거"]
    end

    MoreTools -->|No - Sub-agent 스폰| ST
    SC --> StopHooks

    MoreTools -->|No - 턴 종료| StopHooks

    subgraph STOP ["🟠 Stop — 응답 턴 종료 시"]
        direction TB
        CG["completion-gate\n· SIMPLE: Phase S3 완료 여부\n· NORMAL dev: 미완료 phase 차단\n· verification: round 3회 연속 통과"]
        AC["stop-active-cleanup\ndone 상태 .active 자동 삭제"]
        BC["stop-bouncer-compat\nNORMAL 팀 작업 중\n미커밋 체크 스킵"]
    end

    StopHooks --> CG & AC & BC

    CG -->|⛔ Block| BackToClaude
    CG -->|✅ Pass| Response
    AC --> Response
    BC --> Response

    Response([✅ 사용자에게 응답])
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
