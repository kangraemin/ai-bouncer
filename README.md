# ai-bouncer

Claude Code 개발 flow 강제 도구 (v4).

계획 승인 없이 코드 수정 시도 → 차단.

## Flow

```
요청 → 인텐트 판별 → Planning Team + Q&A → 계획 승인
  → Dev Team (Phase 분해 + TDD) → 3회 연속 검증 → 완료
```

## 특징

- **Planning Team**: planner-lead + planner-dev + planner-qa가 팀을 이뤄 계획 수립
- **Q&A 루프**: 연속 3회 "질문 없음" 시 계획 확정
- **Document-Driven**: 모든 산출물을 `docs/<task>/` 에 저장, 에이전트는 파일에서만 상태 읽기
- **개발 Phase 분해**: Lead가 고수준 계획 → 독립적 개발 단위로 분해
- **3회 연속 검증**: verifier가 plan 대비 구현 충실도 검증, 실패 시 리셋

## 설치

```bash
bash <(curl -sL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

## 언인스톨

```bash
bash install.sh --uninstall
```

## 업데이트

```bash
bash install.sh --update
```

## 포함 파일

### 에이전트
- `agents/intent.md` — Phase 0: 인텐트 판별
- `agents/planner-lead.md` — Phase 1: Planning Team 리드
- `agents/planner-dev.md` — Phase 1: 기술 관점 기여
- `agents/planner-qa.md` — Phase 1: 품질/테스트 관점 기여
- `agents/lead.md` — Phase 3: 팀 규모 판단 + Phase 분해 + 오케스트레이션
- `agents/dev.md` — Phase 3: 구현
- `agents/qa.md` — Phase 3: TC 작성 + 테스트 실행
- `agents/verifier.md` — Phase 4: 종합 검증 + 3회 루프

### 커맨드 & 훅
- `commands/dev.md` — `/dev` 스킬 (전체 플로우 오케스트레이션)
- `hooks/plan-gate.sh` — PreToolUse: 계획 미승인 / TC 미정의 시 코드 수정 차단
- `hooks/doc-reminder.sh` — PostToolUse: 코드 수정 후 문서 미업데이트 경고
- `hooks/completion-gate.sh` — Stop: 검증 미완료 시 응답 종료 차단

## 문서 구조 (작업별)

```
docs/
├── .active                    # 현재 활성 작업
└── <task-name>/
    ├── plan.md                # 고수준 계획
    ├── state.json             # 작업 상태
    ├── phase-1-<feature>/
    │   ├── phase.md
    │   ├── step-1.md          # TC + 구현 내용 + 테스트 결과
    │   └── step-2.md
    └── verifications/
        └── round-1.md
```
