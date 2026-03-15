# Step 2: update.sh (C-5, I-4)

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | C-5: TARGET_DIR sys.argv | grep 'sys.argv' update.sh | sys.argv 기반 경로 | ✅ |
| TC-02 | C-5: inline open('$') 제거 | grep -c "open('\$" update.sh → 0 | 인라인 경로 없음 | ✅ |
| TC-03 | I-4: realpath 실패 방지 | grep '! -f.*update.sh' update.sh | 파일 존재 확인 | ✅ |
| TC-04 | update 실행 테스트 | bash update.sh | 에러 없이 완료 | ✅ |

## 실행출력

TC-01~03: grep 확인 완료
TC-04: bash update.sh → 1개 업데이트, 17개 변경 없음 (정상)
