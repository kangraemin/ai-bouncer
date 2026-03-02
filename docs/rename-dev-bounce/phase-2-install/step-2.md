# Step 2: CLAUDE.md 관리 블록 주입 로직 추가

## 완료 기준
- install.sh에 `ai-bouncer-rule start` / `ai-bouncer-rule end` 마커를 사용한 관리 블록 정의가 존재한다
- 주입 내용에 `/dev-bounce 스킬을 먼저 호출` 규칙 문자열이 포함된다
- CLAUDE.md 주입 로직이 "파일 설치" 섹션 이후, "settings.json 설정" 섹션 이전에 위치한다
- 이미 블록이 있을 때 중복 추가 없이 마커 기반으로 교체하는 로직이 존재한다
- CLAUDE.md가 없을 때 신규 생성하는 분기가 존재한다

## 테스트 케이스

| TC | 시나리오 | 기대 결과 | 실제 결과 |
|---|---|---|---|
| TC-1 | install.sh 파일에서 `ai-bouncer-rule start` 문자열 검색 | 문자열 존재 (grep exit code 0) | PASS (line 270, 274) |
| TC-2 | install.sh 파일에서 `ai-bouncer-rule end` 문자열 검색 | 문자열 존재 (grep exit code 0) | PASS (line 271, 277) |
| TC-3 | install.sh 파일에서 `/dev-bounce 스킬을 먼저 호출` 문자열 검색 | 문자열 존재 (grep exit code 0) | PASS (line 276) |
| TC-4 | install.sh에서 CLAUDE.md 주입 섹션의 줄 번호가 파일 설치 섹션(header "파일 설치") 이후이고 settings.json 설정 섹션(header "settings.json 설정") 이전임을 확인 | CLAUDE.md 주입 코드의 줄 번호: 파일 설치 header < CLAUDE.md 주입 < settings.json header | PASS (파일설치:215 CLAUDE주입:270 settings설정:301) |
| TC-5 | install.sh에 기존 블록이 있을 때 교체(replace)하는 로직 확인 — start/end 마커 모두 감지 시 `d_start != -1 and d_end != -1` 분기로 교체 | 해당 조건 분기 코드가 install.sh에 존재 | PASS (`s != -1 and e != -1` 분기로 교체, line 283) |
| TC-6 | install.sh에 CLAUDE.md 파일이 없을 때(`if [ ! -f "$CLAUDE_FILE" ]` 또는 동등한 조건) 신규 생성하는 분기 존재 | 파일 없음 조건 분기 코드가 install.sh에 존재 | PASS (`else:` at line 291, `os.path.exists` 조건 불충족 시 신규 생성) |

## 구현 내용

- install.sh의 `# ── settings.json에 hooks 등록` 섹션 바로 앞에 `# ── CLAUDE.md 규칙 주입` 섹션 추가
- Python 인라인 스크립트로 3가지 분기 처리:
  1. 기존 CLAUDE.md에 마커 블록 있음 → `s != -1 and e != -1` 조건으로 교체
  2. 기존 CLAUDE.md에 마커 블록 없음 → 파일 끝에 블록 추가
  3. CLAUDE.md 파일 없음 → 신규 생성 후 블록 주입
- 마커: `# --- ai-bouncer-rule start ---` / `# --- ai-bouncer-rule end ---`
- 주입 내용: `/dev-bounce` 스킬을 먼저 호출할 것 규칙

## 변경 파일

- `install.sh`: CLAUDE.md 규칙 주입 섹션 추가 (line 260~299)
- `docs/rename-dev-bounce/phase-2-install/step-2.md`: 구현 결과 문서화

## 빌드

- 명령: `bash -n install.sh`
- 결과: SYNTAX OK

## 검증 명령어

```bash
# TC-1
grep -n "ai-bouncer-rule start" /Users/ram/programming/vibecoding/ai-bouncer/install.sh

# TC-2
grep -n "ai-bouncer-rule end" /Users/ram/programming/vibecoding/ai-bouncer/install.sh

# TC-3
grep -n "dev-bounce.*스킬을 먼저 호출" /Users/ram/programming/vibecoding/ai-bouncer/install.sh

# TC-4 (줄 번호 비교)
INSTALL_LINE=$(grep -n 'header "파일 설치"' /Users/ram/programming/vibecoding/ai-bouncer/install.sh | cut -d: -f1)
CLAUDE_LINE=$(grep -n "ai-bouncer-rule start" /Users/ram/programming/vibecoding/ai-bouncer/install.sh | head -1 | cut -d: -f1)
SETTINGS_LINE=$(grep -n 'header "settings.json 설정"' /Users/ram/programming/vibecoding/ai-bouncer/install.sh | cut -d: -f1)
echo "파일설치:$INSTALL_LINE CLAUDE주입:$CLAUDE_LINE settings설정:$SETTINGS_LINE"
[ "$INSTALL_LINE" -lt "$CLAUDE_LINE" ] && [ "$CLAUDE_LINE" -lt "$SETTINGS_LINE" ] && echo "TC-4 PASS" || echo "TC-4 FAIL"

# TC-5
grep -n "d_start != -1 and d_end != -1" /Users/ram/programming/vibecoding/ai-bouncer/install.sh

# TC-6
grep -n "ai-bouncer-rule" /Users/ram/programming/vibecoding/ai-bouncer/install.sh | grep -E "if.*!.*-f|not.*exist|new_dst|신규"
```
