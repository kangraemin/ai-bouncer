<div align="center">

# ai-bouncer

**Claude Code가 개발 작업의 단계를 건너뛰지 못하게 하는 hook 엔진**

</div>

## 이 하네스가 하는 일

1. config 안에 **모드**를 여러 개 둘 수 있다.
2. 모드에는 plan 단계가 있는 모드도 있고, 없는 모드도 있다.
3. 모드의 **마지막 단계까지 오지 않았으면 Stop hook에서 멈출 수 없다.**
4. 단계마다 할 일(md 파일로도 줄 수 있다)을 수행하고, 다 끝나면 다음 단계로 넘어간다.
5. 단계에는 **역할(prompt)과 조건(run)** 을 준다.

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

이것 말고는 없다.

<br>

## 설치

```bash
# 설치 — 엔진은 전역 한 벌, 지금 레포에도 켠다
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash

# 업데이트 (레포 설정은 보존)
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s update

# 삭제 — 이 레포에서 끄기 / 전역 엔진까지
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall
curl -fsSL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/get.sh | bash -s uninstall --global
```

설정이 없는 레포
- 새 세션을 시작할 때 켤지 묻는다.
- 켜면(`bouncer init`) 기본값을 채운 `.claude/ai-bouncer/workflow.yaml`이 생긴다.
- 켜지 않으려면 `bouncer init --decline`을 쓴다.

설정 파일은 있는데 단계 설정이 없는 레포
- 새 세션을 시작할 때 기본값을 쓸지 직접 정할지 묻는다.
- 기본값을 쓰려면 `bouncer init --defaults`를 쓴다.

<br>

## 설정 (`.claude/ai-bouncer/workflow.yaml`)

```yaml
workflows:                         # 모드. 이름·개수는 마음대로 정한다
  plan:
    label: 계획을 세우고 승인받은 뒤 구현
    stages: [plan, implement, verify, finalize]
  simple:
    stages: [implement, verify, finalize]
  supersimple:
    stages: [implement, verify, finalize]
    choosable: {verify: auto}      # 이 모드에서만 고르는 방식을 덮어쓴다

stages:
  plan:
    prompt_file: prompts/plan.md   # 할 일을 md 파일로
  implement:
    prompt: 계획대로 구현한다.
  verify:
    prompt: 실제로 실행해서 확인한다.
    run: npm run lint              # 끝내려 할 때 돈다. 전부 exit 0 이어야 다음 단계로 간다
    choosable: ask
    items:
      test:   {label: 유닛 테스트, run: npm test}
      e2e:    {label: e2e,        run: npx playwright test}
      review: {label: 변경분 리뷰, prompt: git diff 를 끝까지 읽고 고친다.}
  finalize:
    prompt: 변경 파일을 개별 git add 하고 커밋·push 한다.
```

엔진 기본값(`config/default.yaml`) 위에 덧붙는다.
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

### 오래 걸리는 검사

run은 Stop hook 안에서 돈다. 합계 상한은 `BOUNCER_RUN_BUDGET`(기본 1700초)이다. 수 분 걸리는 검사는 이렇게 나눈다.
- 모델이 직접 돌린다. 테스트가 결과 파일을 남기게 한다.
- run에서는 결과 파일만 확인한다.

```yaml
run: "bouncer fresh .ai-bouncer/test-result && grep -qx 'fail: 0' .ai-bouncer/test-result"
```

`bouncer fresh <파일>`
- 그 파일이 없으면 exit 2로 실패한다.
- 작업 시작 뒤 바뀐 파일보다 오래됐어도 exit 2로 실패한다.
- 그래서 고친 뒤 다시 돌리지 않은 옛 결과로는 통과하지 못한다.

<br>

## 명령

| 명령 | 용도 |
|---|---|
| `bouncer scan` | 이 세션의 작업, 모드, 고를 항목 |
| `bouncer start <모드> <slug> [--pick 단계=id,…]` | 작업 시작. 고르는 단계(ask·auto)는 전부 답해야 한다 |
| `bouncer status` | 현재 단계의 지시와 검사 |
| `bouncer cancel` | 작업 취소 |
| `bouncer workflows` | 모드 목록 |
| `bouncer check` | workflow.yaml 검사 |
| `bouncer fresh <파일>` | run용: 결과 파일이 최신인지 |
| `bouncer init [--defaults\|--decline]` | 레포에 켜기 / 빈 설정에 기본값 채우기 / 켜지 않기 |

<br>

## 구조

```
~/.claude/ai-bouncer/        전역 엔진 한 벌 (설치·업데이트가 통째로 바꾼다)
  engine/  bouncer.sh  compile.py  init.sh  default.yaml  prompts/
  hooks/   session-start.sh  pre-tool.sh  stop.sh  session-end.sh
<레포>/.claude/ai-bouncer/
  workflow.yaml              레포 설정 (커밋 대상)
  workflow.compiled.json     기본값과 합친 결과 (세션 시작 때 다시 만든다)
<레포>/.ai-bouncer/tasks/    작업 상태 (gitignore)
```

테스트: `bash tests/run-all.sh`
