# Phase 2: Install/Update/Uninstall + Test 수정

## 목표
install.sh, update.sh, uninstall.sh, tests의 버그/개선 7건 수정

## 범위
- install.sh (C-4, C-5, I-5, M-3)
- update.sh (C-5, I-4)
- uninstall.sh (M-2)
- tests/test-bash-gate.sh, tests/test-plan-gate.sh (I-6)

## Steps

### Step 1: install.sh (C-4, C-5, I-5, M-3)
- C-4: JSON heredoc → python3 안전 생성
- C-5: Python 인라인 경로 인젝션 방지
- I-5: 누락 이슈 (해당 시)
- M-3: TODO → NOTE

### Step 2: update.sh (C-5, I-4)
- C-5: Python 인라인 경로 인젝션 방지
- I-4: realpath 비교 실패 방지

### Step 3: uninstall.sh (M-2)
- BOUNCER_HOOKS 하드코딩 → hooks.json 동적 읽기

### Step 4: tests (I-6)
- $HOME 직접 오염 → 임시 디렉토리 기반
