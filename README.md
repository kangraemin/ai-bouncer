<div align="center">

# ai-bouncer

**Claude Code가 개발 작업을 건너뛰지 못하게 막는 hook 엔진**

계획 승인 · 검증 통과 · 커밋 — 워크플로우를 프롬프트가 아니라 **실행 결과로** 강제한다.

</div>

```bash
# 설치 — 프로젝트 루트에서
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash

# 업데이트 (설정은 보존)
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s update

# 삭제
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall
```

<br>

## 왜

Claude에게 "테스트 돌려봐"라고 하면 돌린다. 대개는.

문제는 **안 돌렸을 때도 돌렸다고 말한다는 것**이다. 프롬프트로 쓴 규칙은
지켜졌는지 확인할 방법이 없고, 확인할 수 없는 규칙은 규칙이 아니다.

ai-bouncer는 규칙을 **엔진이 관찰할 수 있는 사실**로 바꾼다.

| 자기 보고 | ai-bouncer |
|---|---|
| "테스트 통과했습니다" | 엔진이 명령을 실행하고 **종료코드**를 본다 |
| "계획을 승인받았습니다" | hook이 **ExitPlanMode 승인**을 관찰한다 |
| "다음 단계로 넘어갑니다" | **hook만** 단계를 넘긴다. 모델은 못 넘긴다 |

<br>

## 어떻게 쓰나

설치하면 `/dev-bounce`가 생긴다. 그냥 평소처럼 말하면 된다.

```
당신:  결제 금액 반올림이 안 돼. 고쳐줘.

Claude: ❓ 어떤 모드로 진행할까요?
           ○ plan   — 계획을 세우고 승인받은 뒤 구현
           ○ simple — 계획 없이 바로 구현
```

이후는 엔진이 단계마다 지시를 주입한다. 조건을 못 채우면 다음 단계로 못 간다.

```
plan ──▶ implement ──▶ verify ──▶ finalize ──▶ done
 │            │           │  ▲         │
 │            │           └──┘         └── 워킹트리가 깨끗해야 통과
 │            └── push 차단        on_fail: 구현으로 반송
 └── 파일 수정 차단 · plan mode 승인 필요
```

`bouncer` 명령은 **모델이 부르는 것**이다. 사람은 칠 일이 없다.

<br>

## 워크플로우는 데이터다

단계를 바꾸고 싶으면 `.claude/ai-bouncer/workflow.yaml` 한 파일만 고친다.
엔진 코드는 건드리지 않는다.

```yaml
workflows:
  plan:
    label: 계획을 세우고 승인받은 뒤 구현
    stages: [plan, implement, verify, finalize, done]

stages:
  verify:
    on_fail: implement            # 막히면 구현 단계로 되돌아간다
    steps:
      - label: 유닛 테스트
        run: "npm test -- --run"
        blocking: true            # 종료코드 0이어야 통과. 말로는 못 넘어간다

      - label: e2e
        run: "npx playwright test"
        blocking: true
        optional: true            # 시작할 때 할지 말지 물어본다

      - label: 실기기 확인
        inject: 시뮬레이터로 못 잡는 것을 실기기에서 확인해라.
        blocking: true            # 실제 사용자 턴이 있어야 통과
    forbid:
      edit_files: true            # 수정은 구현 단계에서만
      push: true
      reason: 검증 단계에서는 코드를 고칠 수 없다.
```

스테이지 키는 `steps` / `forbid` / `on_fail` 셋뿐이다.
새 단계를 만들고 싶으면 `stages:`에 정의를 쓰고 체인 배열에 이름을 끼워넣으면 된다.

📖 [스키마 전체](docs/SCHEMA.md) · 🧩 [실사용 예시 6종](examples/) — 최소 · 웹 · 앱 · 백엔드 · 모노레포 · 스킬연동

<br>

## 통과 조건 4가지

| 형태 | 판정 주체 | 모델이 위조 가능? |
|---|---|:---:|
| `run` + `blocking: true` | 실제 종료코드 | ❌ |
| `inject` + `blocking: true` | 실제 사용자 턴 발생 | ❌ |
| `blocking: plan_approved` | hook이 ExitPlanMode 승인 관찰 | ❌ |
| `blocking: skill:<이름>` | hook이 스킬 호출 관찰 | ❌ |

무엇이 "성공"인지는 셸이 정한다 — `run: "! grep -rn TODO src/"` 처럼.
스키마에 `exit`·`stdout_matches` 같은 키를 두지 않은 이유다.

<br>

## 병렬 작업

다른 세션이 이미 작업 중이면 시작이 거부된다. 같은 트리에서 둘이 돌면 충돌하니까.

```bash
bouncer start plan "hotfix" --parallel
```

별도 브랜치와 **레포 밖** worktree가 만들어지고, base 브랜치가 그 시점에 기록된다.
끝나면 `bouncer worktree finalize`가 base로 rebase → FF 머지 → 정리한다.

<br>

## 구버전에서 올라오기

구버전은 `~/.claude/ai-bouncer/`에 전역으로 깔렸다. 신규는 전역을 쓰지 않는다.

```bash
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s migrate --apply --install
```

전역 hook·디렉토리·스킬·`CLAUDE.md` 블록을 정리하고, 구버전을 쓰던 프로젝트 전부에
신규를 설치한다. ai-bouncer가 스스로 설치한 것만 건드리고, `settings.json`과
`CLAUDE.md`는 백업을 남긴다. 중간에 끊겨도 다시 실행하면 이어서 진행된다.

세션을 시작하면 구 업데이터가 이 이관을 자동으로 실행하기도 한다. 다만 구버전에
자기 갱신 경로 버그가 있어 발동하지 않는 환경이 있으므로, 자동으로 넘어오지 않았다면
위 명령을 직접 실행하면 된다.

<br>

## 설계 원칙

1. **워크플로우는 데이터다.** 단계 추가·삭제·순서변경은 yaml 편집으로 끝난다.
2. **`current_stage`는 hook만 쓴다.** 모델의 `state.json` 수정은 차단된다.
3. **자기 보고는 게이트가 아니다.** 통과 판정은 위 4가지로만 한다.
4. **설정 파일은 하나다.** 기본값은 코드에 있어 새 설정이 생겨도 yaml을 안 고쳐도 된다.
5. **런타임 의존성은 `jq`뿐이다.** yaml은 설치·변경 시점에 json으로 컴파일된다.
6. **fail-open 금지.** 오타난 스테이지 이름, 없는 프롬프트 파일, 해석이 갈리는 YAML
   앵커는 전부 컴파일 단계에서 거부한다.

<br>

## 설치되는 것

```
<프로젝트>/
├── .claude/
│   ├── ai-bouncer/
│   │   ├── workflow.yaml          ← 유일한 설정 파일
│   │   ├── prompts/ engine/ hooks/ scripts/
│   │   └── workflow.compiled.json ← 자동 생성 (gitignore)
│   ├── settings.json              ← hook 5개 등록 (남의 hook은 건드리지 않는다)
│   └── skills/dev-bounce/
├── .ai-bouncer/                   ← 런타임 상태 (gitignore)
└── CLAUDE.md                      ← 규칙 블록 (마커 밖 내용은 보존)
```

hook 경로는 `${CLAUDE_PROJECT_DIR}` 기준이라 팀원과 커밋을 공유해도 깨지지 않는다.

| hook | 역할 |
|---|---|
| `SessionStart` | 재컴파일, 방치된 잠금 정리, 진행 중 작업 복원 |
| `PreToolUse` | `forbid` 강제 — 타임아웃되면 차단이 안 되므로 극단적으로 가볍다 |
| `PostToolUse` | ExitPlanMode·Skill 관찰 |
| `Stop` | **엔진 본체** — step 수행, 통과 판정, 단계 전이 |
| `SessionEnd` | 자기 잠금만 해제 (예산 1.5초) |

<br>

## 테스트

```bash
bash tests/run-all.sh
```

케이스별로 나뉘어 있다 — plan/simple 전 구간, `on_fail` 반송, optional 건너뛰기,
`skill:` 게이트, 무한루프 상한, 다중 세션 격리, worktree 병렬·FF 머지, `forbid` 경로
스코프, 컴파일 거부 12종, 파서 동등성, 방치 잠금 정리, `bouncer run`, abort·재시도,
재컴파일, 설치·제거.

<br>

## 요구사항

`git` · `jq` · `python3` · Claude Code

<div align="center">
<br>
<sub>MIT</sub>
</div>
