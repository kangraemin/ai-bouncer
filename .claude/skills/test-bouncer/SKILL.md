---
name: test-bouncer
description: ai-bouncer E2E 테스트 실행. install, uninstall, update, hook 동작을 자동 검증. 사용자가 "테스트 돌려", "e2e 실행", "설치 검증", "bouncer 테스트" 등을 요청하면 이 스킬 사용. ai-bouncer 변경 후 검증이 필요한 모든 상황에서 사용할 것.
---

# test-bouncer

ai-bouncer의 install/uninstall/update/hook 동작을 E2E로 검증하는 스킬.
임시 git repo를 만들어 실제 설치 → 파일 검증 → hook 테스트 → update → uninstall → 재설치까지 전체 사이클을 테스트한다.

---

## 사용 시점

- install.sh / uninstall.sh / hook 코드 수정 후
- 새 hook이나 agent 추가 후
- settings.json 구조 변경 후
- PR 전 최종 검증

---

## 실행

### 1. 전체 E2E (설치 → hook → update → uninstall → 재설치)

```bash
bash tests/e2e-full.sh
```

임시 git repo에서 전체 사이클을 검증한다. exit code가 실패 수.

### 2. Hook 단위 테스트 (소스 기준)

```bash
bash tests/e2e-hooks.sh
```

소스 `hooks/` 디렉토리에서 직접 hook을 실행하여 로직을 검증한다.
설치 과정은 테스트하지 않으므로 hook 로직 변경 시 빠른 피드백용.

---

## 결과 해석

출력 마지막에 통과/실패 수가 표시된다:

```
결과: ✅ 55 통과 / ❌ 0 실패
```

- exit code 0 = 전체 통과
- exit code > 0 = 실패 수

실패 항목은 `❌` 옆에 구체적 원인(파일 없음, 패턴 미매칭 등)이 표시된다.

---

## 테스트 범위

### e2e-full.sh

| 섹션 | 검증 내용 |
|------|-----------|
| 1. 설치 | `install.sh --ci`로 신규 설치 |
| 2. 파일 검증 | hooks(8), agents(8), skill(1), settings.json(7), CLAUDE.md(2), 실행권한(3) |
| 3. Hook 기능 | plan-gate, bash-gate, subagent-track/cleanup, completion-gate, 위임 에이전트 |
| 4. Update | `--update` 후 파일/hook 유지 확인 |
| 5. Uninstall | 파일 삭제, settings.json hook 제거, CLAUDE.md 규칙 제거 확인 |
| 6. Re-install | uninstall 후 재설치 정상 동작 확인 |

### e2e-hooks.sh

plan-gate, bash-gate, bash-audit, subagent-track/cleanup, completion-gate, 예외 경로 등 25개 케이스.

---

## 결과 보고 형식

테스트 실행 후 사용자에게 보고:

```
[E2E 결과]
✅ e2e-full.sh: N/N 통과
✅ e2e-hooks.sh: N/N 통과 (선택 실행 시)

실패 항목: (있으면 목록)
```

---

## 주의사항

- e2e-full.sh는 임시 디렉토리에서 실행되므로 현재 프로젝트에 영향 없음
- e2e-hooks.sh는 프로젝트 내 `docs/2026-03-08/e2e-hook-hardening/` 디렉토리를 사용 (기존 테스트 환경)
- 두 테스트 모두 `python3`과 `jq` 의존
