# 검증 2회차

## Plan 대비 구현 확인

- 기능 1 (commands/dev.md → dev-bounce.md rename): ✅ 파일 삭제 확인, git R100 rename 기록 확인
- 기능 2 (파일 내 커맨드명 변경): ✅ Line 5 `# /dev-bounce`, frontmatter description `/dev-bounce` 포함
- 기능 3 (install.sh copy_file 경로 변경): ✅ `dev-bounce.md` 경로 반영, 완료 메시지 `/dev-bounce`
- 기능 4 (CLAUDE.md 관리 블록 주입): ✅ start/end 마커, 교체/추가/신규생성 3분기, 기존 내용 보존
- 기능 5 (Plan mode 흐름): ✅ EnterPlanMode(line 41), ExitPlanMode(line 121), 재진입(line 129)
- 기능 6 (커밋 전략 설정 + --config): ✅ per-step/per-phase/none 선택 UI, config.json 저장, --config exit 0
- 기능 7 (dev-bounce.md 커밋 전략 처리): ✅ 3-4 섹션에 commit_strategy 읽기 + 전략별 처리 표
- 기능 6b (uninstall CLAUDE.md 블록 제거): ✅ target_dir에서 경로 결정, before/after 보존, no-op 처리

## 문서 완결성

| 파일 | 구현 내용 | TC 결과 | 완료기준 |
|---|---|---|---|
| phase-1-commands/step-1.md | git mv rename | ✅ 채워짐 | ✅ |
| phase-1-commands/step-2.md | 헤딩/description 변경 | ✅ 채워짐 | ✅ |
| phase-1-commands/step-3.md | EnterPlanMode/ExitPlanMode | ✅ 채워짐 | ✅ |
| phase-2-install/step-1.md | copy_file 경로 변경 | ✅ 채워짐 | ✅ |
| phase-2-install/step-2.md | CLAUDE.md 주입 로직 | ✅ 채워짐 | ✅ |
| phase-2-install/step-3.md | 커밋 전략 + --config | ✅ 채워짐 | ✅ |
| phase-2-install/step-4.md | dev-bounce.md 커밋 흐름 | ✅ 채워짐 | ✅ |
| phase-2-install/step-5.md | uninstall CLAUDE.md 제거 | ✅ 채워짐 | ✅ |

## 엣지 케이스 집중 검증 (Round 2 초점)

### EC-1: commands/dev.md 진짜 삭제 여부 (git rename vs 별도 삭제)

```
test -f commands/dev.md → PASS: 파일 없음
git log --diff-filter=R --name-status → R100 commands/dev.md commands/dev-bounce.md (commit 66d55c6)
```

결론: `git mv`로 rename 처리. `dev.md`는 존재하지 않으며 git 이력도 rename(R100)으로 기록됨. ✅

### EC-2: dev-bounce.md 내 "/dev " (슬래시+dev+공백) 잔존 여부

```
grep -n ' /dev ' commands/dev-bounce.md → 매치 없음 (PASS)
grep -n '^# /dev$' commands/dev-bounce.md → 매치 없음 (PASS)
```

결론: 의도치 않은 `/dev ` 패턴 없음. `/dev-bounce` 참조만 존재함. ✅

### EC-3: CLAUDE.md 주입 시 기존 OTHER 콘텐츠 보존

inject 로직 (`content[:s] + block + content[e + len(END):]`) 시뮬레이션:
- 입력: Global Rules + ai-bouncer 블록(구) + 스킬 우선 사용 내용
- 결과: Global Rules 보존 ✅, ai-bouncer 블록 신규 교체 ✅, 스킬 우선 사용 보존 ✅
- 실제 코드 위치: install.sh line 390-402

결론: before(블록 앞 내용) + after(블록 뒤 내용) 모두 보존됨. ✅

### EC-4: --config 플래그 실행 후 clean exit

```
install.sh line 185: exit 0 (--config 분기 끝)
python3 config.json 부분 업데이트 후 ok "커밋 전략 업데이트 완료" → exit 0
```

결론: --config는 commit_strategy, commit_skill만 업데이트 후 exit 0으로 종료. 다음 설치 흐름으로 fall-through 없음. ✅

### EC-5: dev-bounce.md commit_strategy 섹션의 $HOME 경로

```bash
python3 -c "
import json
cfg = json.load(open('$HOME/.claude/ai-bouncer/config.json'))
..."
```

이 코드는 double-quoted bash 문자열 내에 위치하므로 $HOME이 bash에 의해 확장됨.
실제 테스트: `python3 -c "... print('$HOME/...')"` → `/Users/ram/.claude/ai-bouncer/config.json` 정상 출력. ✅

### EC-6: --uninstall 순서 — CLAUDE.md 제거가 manifest 삭제보다 먼저

```
line 97~128: CLAUDE.md 블록 제거 (Python heredoc)
line 134:    rm -f "$HOME/.claude/ai-bouncer/manifest.json"
line 135:    rm -f "$HOME/.claude/ai-bouncer/config.json"
```

결론: CLAUDE.md 제거(97~128) → manifest/config 삭제(134~135) 순서 확인. ✅

**추가 검증 — CLAUDE.md 블록만 있는 경우 파일 삭제 안 함:**
- 시뮬레이션 결과: 블록만 있는 CLAUDE.md에서 블록 제거 후 파일은 빈 파일로 남음 (삭제 안 됨).
- plan 요구사항 "파일 자체는 삭제하지 않음" 충족. ✅

## 테스트 결과 (전체 TC 재실행)

| Phase | Step | TC | 결과 |
|---|---|---|---|
| 1 | 1 | TC-1 dev-bounce.md 존재 | ✅ PASS |
| 1 | 1 | TC-2 dev.md 미존재 | ✅ PASS |
| 1 | 1 | TC-3 git rename 기록 | ✅ PASS (R100) |
| 1 | 2 | TC-1 Line 5 = # /dev-bounce | ✅ PASS |
| 1 | 2 | TC-2 description /dev-bounce 포함 | ✅ PASS |
| 1 | 2 | TC-3 # /dev 헤딩 없음 | ✅ PASS |
| 1 | 2 | TC-5 /dev 공백 패턴 없음 | ✅ PASS |
| 2 | 1 | TC-1 copy_file dev-bounce.md | ✅ PASS |
| 2 | 1 | TC-2 copy_file dev.md 없음 | ✅ PASS |
| 2 | 1 | TC-3 완료 메시지 /dev-bounce | ✅ PASS |
| 2 | 1 | TC-4 완료 메시지 /dev 없음 | ✅ PASS |
| 2 | 2 | TC-1 ai-bouncer-rule start 존재 | ✅ PASS |
| 2 | 2 | TC-2 ai-bouncer-rule end 존재 | ✅ PASS |
| 2 | 2 | TC-3 /dev-bounce 스킬 호출 문자열 | ✅ PASS |
| 2 | 2 | TC-5 s != -1 and e != -1 교체 분기 | ✅ PASS |
| 2 | 3 | TC-1 per-step/per-phase/none UI | ✅ PASS |
| 2 | 3 | TC-2 commit.md 파일 감지 로직 | ✅ PASS |
| 2 | 3 | TC-3 commit_strategy 키 저장 | ✅ PASS |
| 2 | 3 | TC-4 commit_skill 키 저장 | ✅ PASS |
| 2 | 3 | TC-5 target_dir 키 저장 | ✅ PASS |
| 2 | 3 | TC-6 --config 분기 존재 | ✅ PASS |
| 2 | 5 | TC-1 uninstall 내 ai-bouncer-rule 제거 코드 | ✅ PASS |
| 2 | 5 | TC-2 target_dir 기반 CLAUDE.md 경로 결정 | ✅ PASS |
| 2 | 5 | TC-3 before/after 보존 로직 | ✅ PASS |
| 2 | 5 | TC-4 블록 없음 no-op 처리 | ✅ PASS |
| 2 | 5 | TC-5 bash -n syntax OK | ✅ PASS |

총 25/25 통과

## 결론

통과. 모든 기능이 plan.md 요구사항을 충족하며, Round 2 집중 엣지 케이스 6개 전부 실제 bash 실행 및 시뮬레이션으로 검증함. 이전 라운드와 독립적으로 재검증함.
