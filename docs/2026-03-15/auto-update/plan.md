# ai-bouncer 자동 업데이트 기능 추가

## Context

현재 ai-bouncer는 수동으로 bash update.sh를 실행해야 업데이트됨.
worklog-for-claude의 자동 업데이트 패턴(SessionStart hook + 24h throttle + bootstrap)을 적용하여,
세션 시작 시 자동으로 최신 버전을 체크하고 업데이트하도록 한다.

## 변경 파일별 상세

### 1. scripts/update-check.sh (신규)
- 24h throttle, GitHub API SHA 비교, bootstrap, git clone + update.sh 실행
- --force, --check-only 옵션
- 네트워크 실패 시 조용히 종료

### 2. install.sh (수정)
- scripts/ 디렉토리 동적 복사 추가
- settings.json에 SessionStart hook 등록 (enforcement_mode 무관)

### 3. update.sh (수정)
- scripts/ 디렉토리 동적 복사 추가
- post-update: SessionStart hook 등록

### 4. uninstall.sh (수정)
- scripts/ 디렉토리 정리
- SessionStart hook 제거

## 검증
- bash scripts/update-check.sh --check-only
- bash install.sh --ci 후 settings.json SessionStart hook 확인
- bash update.sh 후 scripts/ 복사 확인
- bash tests/e2e-full.sh 통과
