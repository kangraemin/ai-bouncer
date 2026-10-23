<div align="center">

# ai-bouncer

**Claude Code가 개발 작업을 건너뛰지 못하게 막는 hook 엔진**

계획 승인 · 검증 통과 · 커밋 — 워크플로우를 프롬프트가 아니라 **실행 결과로** 강제한다.

</div>

```bash
# 설치 — 엔진은 전역 한 벌, 지금 레포에도 켠다
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash

# 다른 레포에 켜기 — 설정이 없는 레포는 새 세션을 시작할 때 켤지 묻는다. 직접 켜려면:
bouncer init            # 켜지 않으려면 bouncer init --decline

# 업데이트 (설정은 보존)
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s update

# 삭제 — 이 레포에서 끄기 / 전역 엔진까지
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall --global
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

`bouncer` 명령은 **모델이 부르는 것**이다. 사람은 대개 칠 일이 없다.

막혔을 때 사람이 쓰는 것은 이 셋뿐이다:

| 명령 | 언제 |
|---|---|
| `bouncer status` | 지금 무슨 조건에 막혀 있는지 |
| `bouncer release [--force]` | 세션이 죽어 잠금이 남았을 때. `--force` 가 회수하고, `bouncer resume <task-id>` 로 이어받는다 |
| `bouncer cancel` | 이 작업을 그만둔다 (기록은 남는다) |

엔진이 조건을 포기하고 "이번 작업에서만 건너뛴다"를 제안하면 `bouncer skip <step-id>` 가
열린다. 제안 전에는 거부된다 — 게이트를 처음부터 우회하는 수단이 되지 않도록.
`bouncer workflows` 는 정의된 모드를, `bouncer check` 는 고친 yaml의 유효성을 본다.

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

## 옛 버전(레포별 설치)에서 올라오기

`bash -s update` 한 번이면 된다. 전역 엔진을 깔고, 켠 레포마다 레포 안 엔진·훅·스킬과
프로젝트 `settings.json`의 ai-bouncer hook을 걷어내고 `workflow.yaml`만 남긴다.
이미 열려 있는 세션은 시작할 때 읽은 옛 hook 경로를 계속 부르므로, 그 자리에는 전역 hook으로
넘기는 얇은 파일을 둔다(커밋 대상 아님). 정리된 파일은 레포에서 커밋하면 된다.

<br>

## 설계 원칙

1. **워크플로우는 데이터다.** 단계 추가·삭제·순서변경은 yaml 편집으로 끝난다.
2. **`current_stage`는 hook만 쓴다.** 모델의 `state.json` 수정은 차단된다.
3. **자기 보고는 게이트가 아니다.** 통과 판정은 위 4가지로만 한다.
4. **설정 파일은 하나다.** 기본값은 코드에 있어 새 설정이 생겨도 yaml을 안 고쳐도 된다.
5. **런타임 의존성은 `jq`뿐이다.** yaml은 설치·변경 시점에 json으로 컴파일된다.
6. **fail-open 금지.** 오타난 스테이지 이름, 없는 프롬프트 파일, 중복된 키(가드가
   조용히 덮어써진다), 뒤로 못 가는 `on_fail` 등을 컴파일 단계에서 거부한다.
   YAML 앵커는 pyyaml이 없는 환경에서 해석이 갈리므로 **내장 파서를 쓸 때** 거부한다.

<br>

## 설치되는 것

```
~/.claude/
├── ai-bouncer/                    ← 엔진 + hook + 기본값 (전역 한 벌, 업데이트 때 통째로 교체)
├── settings.json                  ← hook 5개 등록 (남의 hook은 건드리지 않는다)
└── skills/dev-bounce/

<레포>/
├── .claude/ai-bouncer/
│   ├── workflow.yaml              ← 레포 설정 (기본값과 다른 것만). 이게 있는 레포에서만 hook이 일한다
│   └── workflow.compiled.json     ← 자동 생성 (gitignore)
├── .ai-bouncer/                   ← 런타임 상태 (gitignore)
└── CLAUDE.md                      ← 규칙 블록 (마커 밖 내용은 보존)
```

그 밖에:

- `~/.local/bin/bouncer` — 셸에서 부르는 실행 파일. 전역 엔진을 실행한다.
- `~/.local/state/ai-bouncer/` — 켠 레포 목록(`installs`)과 켜지 않기로 한 레포 목록(`declined`).
- `~/.ai-bouncer/worktrees/<repo>/<branch>/` — 병렬 작업용 worktree.
  레포 밖에 두는 이유는 빌드 도구가 긁지 않고 권한 프롬프트도 뜨지 않게 하기 위해서다.

설정이 없는 레포에서는 hook이 아무것도 하지 않는다. 새 세션을 시작할 때만 켤지 한 번 묻고,
거절하면 그 레포에서는 다시 묻지 않는다.

| hook | 역할 |
|---|---|
| `SessionStart` | 재컴파일, 방치된 잠금 정리, 진행 중 작업 복원 |
| `PreToolUse` | `forbid` 강제 — 타임아웃되면 차단이 안 되므로 극단적으로 가볍다 |
| `PostToolUse` | ExitPlanMode·Skill 관찰, 읽기 전용 단계에서 Bash 가 작업 트리를 바꿨는지 감시 |
| `PostToolUseFailure` | 실패한 Bash 도 같은 기준으로 작업 트리 감시 |
| `UserPromptSubmit` | 사용자가 실제로 답했다는 사실만 기록 (내용은 읽지 않는다) |
| `Stop` | **엔진 본체** — step 수행, 통과 판정, 단계 전이 |
| `SessionEnd` | 자기 잠금만 해제 (Claude Code 기본 예산이 1.5초라 이 일만 한다) |

<br>

## 테스트

```bash
bash tests/run-all.sh
```

케이스별로 나뉘어 있다 — plan/simple 전 구간, `on_fail` 반송, optional 건너뛰기,
`skill:` 게이트, 무한루프 상한, 다중 세션 격리, worktree 병렬·FF 머지, `forbid` 경로
스코프, 컴파일 거부 15종, 파서 동등성, 방치 잠금 정리, `bouncer run`, abort·재시도,
재컴파일, Stop 재진입 가드, `on_fail` 무한 왕복 가드, 설치·제거.

<br>

## 요구사항

`git` · `jq` · `python3` · Claude Code

<div align="center">
<br>
<sub>MIT</sub>
</div>
