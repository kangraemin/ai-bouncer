<div align="center">

# ai-bouncer

**Claude Code가 개발 작업의 단계를 건너뛰지 못하게 하는 hook 엔진**

</div>

## 이 하네스가 하는 일

1. config 안에 **모드**를 여러 개 둘 수 있다.
2. 모드마다 단계 순서가 다르다. 예를 들어 plan 모드는 계획부터, simple 모드는 바로 구현부터 시작한다.
3. 모드의 **마지막 단계까지 오지 않았으면 Stop hook에서 멈출 수 없다.**
4. 단계마다 할 일(md 파일로도 줄 수 있다)을 수행하고, 다 끝나면 다음 단계로 넘어간다.
5. 단계에는 **역할(prompt)과 조건(run)** 을 준다.
   - prompt: 모델이 할 일. 테스트·빌드·e2e 같은 검사도 모델이 prompt 대로 직접 돌린다.
   - run: hook이 결과만 검증한다. 검사를 hook에서 돌리지 않는다.

### 고르기 (choosable)

단계의 세부 항목(items)을 고르는 방식이다.

| 값 | 동작 |
|---|---|
| `ask` | 작업을 시작할 때 **항상 사용자에게 묻는다** |
| `auto` | **AI가** 작업 내용을 보고 고른다 |
| `all` | 고르지 않고 **전부 넣는다** (기본) |

- 고른 결과는 state.json에 적는다.
- 고른 항목의 prompt만 주입하고, 고른 항목의 run만 검사한다.
- items가 없는 단계를 고르게 하면, 그 단계를 할지 말지를 고른다.
- 아무것도 고르지 않은 단계는 건너뛴다.
- 모드마다 방식을 덮어쓸 수 있다. 같은 verify를 simple에선 묻고, supersimple에선 AI가 고르게 할 수 있다.

<br>

## 설치

필요한 것
- git, jq, python3 (pyyaml은 없어도 된다)
- `~/.local/bin`이 PATH에 있어야 한다. `bouncer` 명령이 여기에 깔린다.
  - PATH에 없으면 Claude가 "설치 안 됨"으로 보고 게이트 없이 작업한다.

```bash
# 설치 — 엔진은 전역 한 벌, 지금 레포에도 켠다
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash

# 업데이트 (레포 설정은 보존)
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s update

# 삭제 — 이 레포에서 끄기 / 전역 엔진까지
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall --global
```

처음 켤 때 한 번만 묻는다. 그 뒤로는 묻지 않는다.
- 터미널에서 설치하면 그 자리에서 묻는다. 새 Claude 세션에서 처음 열면 세션이 묻는다.
- 선택지
  - 이 레포에 맞게 정한다 (추천): Claude가 레포의 테스트·린트·빌드 명령을 찾아 추천하고, 대화로 모드·검증·마무리를 정해 workflow.yaml을 쓴다 (`bouncer setup`)
  - 기본값으로 켠다: `bouncer init --defaults`
  - 켜지 않는다: `bouncer init --decline`
- 설정 파일이 비어 있으면 엔진 기본값(plan / simple)으로 돈다. 나중에 바꾸고 싶으면 `bouncer setup`을 다시 돌린다.

첫 작업
1. 새 Claude Code 세션을 연다.
2. 평소처럼 "이 버그 고쳐줘"라고 시킨다. Claude가 `/dev-bounce`로 시작하며 모드와 검증 항목을 묻는다.
3. 그 뒤로는 단계마다 지시가 들어오고, 마지막 단계를 통과해야 끝난다.

<br>

## 설정 (`.claude/ai-bouncer/workflow.yaml`)

```yaml
workflows:                         # 모드. 이름·개수는 마음대로 정한다
  plan:
    label: 계획을 세우고 승인받은 뒤 구현
    stages: [plan, implement, verify, finalize]   # plan 단계 지시는 엔진 기본값을 쓴다
  simple:
    stages: [implement, verify, finalize]
  supersimple:
    stages: [implement, verify, finalize]
    choosable: {verify: auto}      # 이 모드에서만 고르는 방식을 덮어쓴다

stages:
  implement:                       # 할 일은 prompt, 또는 prompt_file: prompts/x.md (이 설정 파일 기준 경로)
    prompt: 계획대로 구현한다.
  verify:
    prompt: 실제로 실행해서 확인한다.
    choosable: ask                 # 검사는 전부 항목으로 두고 시작할 때 고른다
    items:
      test:
        label: 린트·유닛 테스트
        prompt: "`bouncer record test 'npm run lint && npm test'` 로 돌린다."   # 모델이 돌린다
        run: bouncer passed test   # hook 은 결과가 최신이고 통과했는지만 본다
      e2e:
        label: e2e (영향받는 spec 만)
        prompt: "영향받는 spec 만 골라 `bouncer record e2e npx playwright test <spec...>` 로 돌린다."
        run: bouncer passed e2e
      review: {label: 변경분 리뷰, prompt: git diff 를 끝까지 읽고 고친다.}
  finalize:
    prompt: 변경 파일을 개별 git add 하고 커밋·push 한다.
```

엔진 기본값 위에 덧붙는다. 기본값 파일은 소스에선 `config/default.yaml`, 설치본에선 `~/.claude/ai-bouncer/engine/default.yaml`이다.
- `workflows`를 적으면 기본 모드 목록을 통째로 대신한다.
- `stages`는 이름 단위로 교체하거나 추가한다.
- 단계 안에서는 키 단위로, items는 id 단위로 교체한다.

자세한 형식은 [docs/SCHEMA.md](docs/SCHEMA.md), 예시는 [examples/](examples/)에 있다.

<br>

## 흐름

```
/dev-bounce
  └ bouncer scan            모드 목록과 고를 항목(CHOICE)
  └ (ask 항목은 사용자에게 묻고, auto 항목은 AI가 고른다)
  └ bouncer start <모드> <slug> --pick verify=test,review
       → 첫 단계 prompt 주입
  …작업…
  Stop ─┬ 이 단계 prompt 를 아직 안 줬으면 → 주고 막는다
        ├ run 을 돌린다. 실패하면 → 출력과 함께 막는다
        ├ 통과하고 다음 단계가 있으면 → 넘어가고 다음 prompt 를 주며 막는다
        └ 마지막 단계까지 통과했으면 → 끝. 이제야 멈출 수 있다
```

무한 반복은 막는다.
- 같은 사유로 막혔는데 그 사이 도구를 하나도 안 썼으면 놓아준다. 기다리는 중이라는 뜻이다.
- 연속으로 `BOUNCER_MAX_CONTINUE`번(기본 10) 막으면 사용자에게 넘긴다.

모델이 스스로 단계를 넘길 수는 없다.
- 단계는 Stop hook만 넘긴다.
- 상태·설정 파일(`.ai-bouncer/`, `.claude/ai-bouncer/`, `.claude/settings.json`)은 Edit·Write로 고칠 수 없다.

### 검사는 prompt에서 돌리고 run은 결과만 본다

run은 Stop hook 안에서 돈다. 합계 상한은 `BOUNCER_RUN_BUDGET`(기본 1700초)이다.
- 검사를 hook에서 돌리면 시간 초과로 끊긴다.
- 이번 수정에 영향받는 것만 고르는 판단도 hook은 못 한다.

그래서 검사는 이렇게 나눈다.

```yaml
prompt: "`bouncer record e2e npx playwright test <spec...>` 로 돌린다."   # 모델이 돌린다
run: bouncer passed e2e                                                  # hook 은 결과만 본다
```

`bouncer record <이름> <명령>`
- 명령을 돌리고 출력을 `.ai-bouncer/results/<이름>`에 남긴다.
- 마지막 줄에 `exit: <코드>`를 적는다.

`bouncer passed <이름>`
- 결과가 없거나 마지막 줄이 `exit: 0`이 아니면 exit 2로 실패한다.
- 작업 시작 뒤 바뀐 파일보다 결과가 오래됐어도 exit 2로 실패한다.
- 이번 작업을 시작하기 전에 만든 결과도 exit 2로 실패한다.
- 그래서 고친 뒤 다시 돌리지 않은 옛 결과로는 통과하지 못한다.
- 실수와 오래된 결과를 막는 장치다. 모델이 셸로 결과 파일을 일부러 써 넣는 것까지 막지는 않는다.

금방 끝나는 상태 확인(grep, `git status` 등)은 run에 바로 둬도 된다.

<br>

## 명령

| 명령 | 용도 |
|---|---|
| `bouncer scan` | 이 세션의 작업(현재 단계 지시 포함), 모드, 고를 항목 |
| `bouncer start <모드> <slug> [--pick 단계=id,…]` | 작업 시작. 고르는 단계(ask·auto)는 전부 답해야 한다 |
| `bouncer cancel` | 작업 취소 |
| `bouncer check` | workflow.yaml 검사 |
| `bouncer record <이름> <명령>` | prompt용: 검사를 돌리고 결과를 남긴다 |
| `bouncer passed <이름>` | run용: 그 결과가 최신이고 통과했는지 |
| `bouncer init [--defaults\|--decline]` | 레포에 켜기(빈 설정) / 기본값 써 넣기 / 켜지 않기 |
| `bouncer setup` | 이 레포 설정을 사용자와 대화로 정하는 안내 (찾은 검사 명령 포함) |

<br>

## 구조

```
~/.claude/ai-bouncer/        전역 엔진 한 벌 (설치·업데이트가 통째로 바꾼다)
  engine/  bouncer.sh  compile.py  init.sh  setup.sh  default.yaml  prompts/   (소스의 config/ 가 여기로 들어간다)
  hooks/   session-start.sh  pre-tool.sh  stop.sh  session-end.sh
<레포>/.claude/ai-bouncer/
  workflow.yaml              레포 설정 (커밋 대상)
  workflow.compiled.json     기본값과 합친 결과 (세션 시작 때 다시 만든다)
<레포>/.ai-bouncer/          작업 상태 tasks/, 검사 결과 results/ (gitignore)
```

테스트: `bash tests/run-all.sh`
