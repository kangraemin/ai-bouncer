# QA 회귀 E2E 테스트 추가

## 변경 파일별 상세
### `tests/e2e-hooks.sh`
- **변경 이유**: QA 리포트 C-1/C-2/C-3/I-1/I-2 버그에 대한 회귀 테스트 추가
- **Before**: 섹션 14까지 존재 (cancelled + 워크플로우 화이트리스트)
- **After**: 섹션 15 "QA 회귀 테스트" 추가 (TC 6건)

## 검증
- 검증 명령어: `bash tests/e2e-hooks.sh`
- 기대 결과: 전체 통과, 새 TC 6건 포함
