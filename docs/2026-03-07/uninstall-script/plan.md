# install.sh --uninstall → 별도 uninstall.sh 분리

## 변경 사항
- `uninstall.sh`: install.sh에서 uninstall 로직 추출하여 독립 스크립트로 생성
- `install.sh`: --uninstall 블록을 uninstall.sh 호출로 대체 (하위 호환 유지)
- `README.md`: Uninstall 섹션에 `bash uninstall.sh` 추가

## 검증
- `bash uninstall.sh` 단독 실행 (미설치 상태 → 에러 메시지)
- `bash install.sh --uninstall` 하위 호환 확인
