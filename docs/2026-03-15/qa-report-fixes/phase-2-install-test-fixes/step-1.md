# Step 1: install.sh (C-4, C-5, M-3)

## TC (Test Cases)

| TC | 검증 항목 | 방법 | 기대 결과 | 상태 |
|----|----------|------|----------|------|
| TC-01 | C-4: config.json python3 생성 | grep 'python3' install.sh \| grep config | python3 기반 생성 | ✅ |
| TC-02 | C-4: cat heredoc 제거 | grep -c 'cat >.*config.json.*JSON' install.sh → 0 | heredoc 없음 | ✅ |
| TC-03 | C-5: relpath sys.argv 사용 | grep 'sys.argv' install.sh | sys.argv 사용 | ✅ |
| TC-04 | M-3: TODO → NOTE | grep -c '# TODO:' install.sh → 0 | TODO 없음 | ✅ |
| TC-05 | CI 설치 테스트 | CI=true bash install.sh | 에러 없이 완료 | ✅ |

## 실행출력

TC-01: config.json 생성이 python3 heredoc 기반으로 변경됨
TC-02: cat > config.json << JSON 패턴 0건
TC-03: sys.argv 36건 (relpath 포함 전체)
TC-04: # TODO: 0건
TC-05: CI=true bash install.sh → 에러 없이 완료
