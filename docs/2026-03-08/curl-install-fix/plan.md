# curl 원격 설치 버그 수정

## 변경 사항
- install.sh: PACKAGE_DIR 유효성 검사 + git clone fallback 추가
- tests/e2e-install.sh: 설치/제거 e2e 테스트 6개 TC 신규 생성

## 검증
- `bash tests/e2e-install.sh`
