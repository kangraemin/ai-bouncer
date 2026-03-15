# Phase 1: Hook 수정

## 목표
hook 파일 5개의 버그/개선 7건(C-1, C-2, C-3, I-1, I-2, I-3, M-1) 수정

## 범위
- hooks/bash-audit.sh (C-1)
- hooks/subagent-cleanup.sh (C-2)
- hooks/bash-gate.sh (C-3, I-1, M-1)
- hooks/plan-gate.sh (I-1, M-1)
- hooks/subagent-track.sh (I-2, I-3)

## Steps

### Step 1: bash-audit.sh + subagent-cleanup.sh (C-1, C-2)
- C-1: SESSION_ID 기반 snapshot 경로 → bash-gate.sh와 일치
- C-2: grep 실패 시 빈 파일 mv 방지

### Step 2: bash-gate.sh (C-3, I-1, M-1)
- C-3: jq max on null → `max // 0`
- I-1: 산술 비교 변수 sanitize
- M-1: 한국어 grep `LC_ALL=en_US.UTF-8`

### Step 3: plan-gate.sh (I-1, M-1)
- I-1: 산술 비교 변수 sanitize
- M-1: 한국어 grep `LC_ALL=en_US.UTF-8`

### Step 4: subagent-track.sh (I-2, I-3)
- I-2: glob `/` 누락
- I-3: REPO_ROOT fallback
