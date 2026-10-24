# workflow.yaml 스키마

레포 설정 `<레포>/.claude/ai-bouncer/workflow.yaml` 과 엔진 기본값은 **같은 형식**이다.
기본값 파일은 소스에선 `config/default.yaml`, 설치본에선 `~/.claude/ai-bouncer/engine/default.yaml`이다.
레포 설정은 기본값 위에 덧붙는다.

```yaml
workflows:
  <모드>:
    label: 설명                     # 선택. 모드를 고를 때 보인다
    stages: [<단계>, ...]           # 단계 순서
    choosable: {<단계>: ask|auto|all}   # 선택. 이 모드에서만 고르는 방식을 덮어쓴다

stages:
  <단계>:
    prompt: 할 일                   # 또는 prompt_file: prompts/x.md (설정 파일 기준 상대경로)
    run: 명령 | [명령, ...]          # 끝내려 할 때 순서대로 돈다
    items:                          # 세부 항목
      <id>:
        label: 이름
        prompt: 할 일               # 또는 prompt_file
        run: 명령 | [명령, ...]
    choosable: ask | auto | all     # items(없으면 단계 자체)를 고르는 방식. 기본 all
```

키는 이것뿐이다. 모르는 키는 컴파일 오류다. 오타로 규칙이 조용히 사라지지 않게 하려는 것이다.
- 최상위에 쓸 수 있는 키는 `version`, `workflows`, `stages`다. `version`은 허용만 하고 무시한다.
- 단계에 쓸 수 있는 키는 `prompt`, `prompt_file`, `run`, `items`, `choosable`이다.
- 항목에 쓸 수 있는 키는 `label`, `prompt`, `prompt_file`, `run`이다.

## 동작

### 모드와 단계

- 모드를 고르면 그 모드의 `stages`를 순서대로 지난다.
- 마지막 단계의 run까지 통과해야 작업이 끝난다. 그 전에는 Stop hook이 멈추지 못하게 막는다.

### prompt — 역할

- 단계에 들어오면 주입한다.
- 첫 단계는 `bouncer start`가, 이후 단계는 Stop hook이 넘어가면서 주입한다.
- 들어갈 때는 단계 prompt 뒤에 고른 항목들의 prompt를 이어 붙인다.
- 맨 끝에는 엔진이 "이 단계 일만 하고 응답을 끝내라"를 붙인다. 레포가 prompt를 덮어써도 빠지지 않는다.
- 다음 단계의 지시와 단계 순서는 그 단계에 들어가기 전에는 보여 주지 않는다.

### run — 조건

- 검증만 한다. 검사(테스트·빌드·e2e)는 prompt에서 모델이 `bouncer record`로 직접 돌리고, run은 `bouncer passed`로 결과만 본다.
- 모델이 응답을 끝내려 할 때, 작업을 시작한 git 저장소 루트에서 `bash -c`로 돈다.
- 단계 run, 고른 항목들의 run 순서로 돈다.
- 전부 exit 0이면 다음 단계로 넘어간다.
- 하나라도 실패하면 출력 끝 30줄과 함께 막는다.
- 종료코드별로 안내가 다르다.
  - `2`: 아직 통과하지 못했다
  - `124`: 시간 초과
  - `127`: 명령을 찾을 수 없다
- 환경변수로 `BOUNCER_STAGE`, `BOUNCER_TASK_DIR`를 받는다.
- PATH에 `~/.local/bin`이 들어가 있어서 `bouncer` 명령을 쓸 수 있다.
- 합계 시간 상한은 `BOUNCER_RUN_BUDGET`(기본 1700초)이다. 검사를 run에서 돌리면 끊긴다.
- `bouncer record <이름> <명령>`: 명령을 돌려 출력을 `.ai-bouncer/results/<이름>`에 남기고 마지막 줄에 `exit: <코드>`를 적는다.
- `bouncer passed <이름>`: 결과가 없거나, `exit: 0`이 아니거나, 이번 작업 시작 전 것이거나, 작업 중 바뀐 파일보다 오래됐으면 exit 2로 실패한다.
  - 결과는 git 저장소 루트의 `.ai-bouncer/results/`에 쌓인다. 하위 폴더에서 돌려도 같다.
  - 실수와 오래된 결과를 막는 장치다. 셸로 결과 파일을 일부러 써 넣는 것까지 막지는 않는다.
- `bouncer record`의 명령은 인자 하나면 셸 문자열(`'a && b'`)로, 여럿이면 인자 그대로 실행한다.

```yaml
items:
  test:
    prompt: "`bouncer record test npm test` 로 돌린다."
    run: bouncer passed test
```

### choosable — 고르는 방식

| 값 | 시작할 때 |
|---|---|
| `ask` | 사용자에게 묻는다 (AskUserQuestion) |
| `auto` | AI가 작업 내용을 보고 고른다 |
| `all` | 고르지 않는다. 전부 적용 (기본) |

- `ask`·`auto`인 단계는 `bouncer start`에 `--pick <단계>=<id>,<id>`로 빠짐없이 답해야 한다. 빠지면 시작을 거부한다.
- 고른 결과는 state.json의 `choices`에 적는다.
- 그 단계에서는 고른 항목의 prompt만 주입하고, 고른 항목의 run만 돌린다.
- items가 없는 단계는 단계 자체가 선택지다(id = 단계 이름). 고르지 않으면 그 단계를 건너뛴다.
- `--pick <단계>=`처럼 아무것도 고르지 않은 단계는 이번 작업의 체인에서 빠진다.
- 모드의 `choosable`은 그 모드에서 단계의 값을 덮어쓴다.

```yaml
workflows:
  simple:      {stages: [implement, verify, finalize]}                            # verify: 묻는다
  supersimple: {stages: [implement, verify, finalize], choosable: {verify: auto}} # verify: AI가 고른다
stages:
  verify:
    choosable: ask
    items: {...}
```

## 기본값과 합치는 규칙

| 키 | 규칙 |
|---|---|
| `workflows` | 레포가 적으면 기본 모드 목록을 **통째로** 대신한다. 모드 이름은 레포가 정한다 |
| `stages.<단계>` | 같은 이름이면 키 단위로 덮고, 새 이름이면 추가한다 |
| `stages.<단계>.items.<id>` | 같은 id면 교체하고, 새 id면 추가한다 |
| `prompt` / `prompt_file` | 한 쌍이다. 어느 쪽이든 적으면 기본값의 둘 다를 대신한다 |

## 기본값

`config/default.yaml`
- 모드
  - `plan`: plan → implement → verify → finalize
  - `simple`: implement → verify → finalize
- verify 단계는 `choosable: ask`이고, 항목은 `test`(테스트·빌드·린트)와 `review`(변경분 리뷰)다.
- 레포의 검사는 `stages.verify.items.<id>`에 둔다. `stages.verify.run`에 넣으면 고를 수 없고 매번 강제로 돈다.
- 검사는 prompt에서 모델이 `bouncer record`로 돌리고, run은 `bouncer passed`로 결과만 본다. e2e처럼 범위를 고를 수 있으면 영향받는 것만 돌리게 적는다.
- 기본값은 run이 없다. 기본 `test`는 명령을 몰라 검사를 강제하지 않는다. 이 레포에서 무엇으로 검사할지는 레포 설정에 적는다.

레포 설정 예:

```yaml
stages:
  verify:
    items:
      test:
        prompt: "`bouncer record test npm test` 로 돌린다."
        run: bouncer passed test
```

## 옛 형식

`steps`, `forbid`, `on_fail`, `settings`, `base` 같은 옛 키는 없어졌다.
- `bouncer init`(업데이트 때 자동으로 돈다)이 옛 파일을 새 형식으로 바꾼다.
- run 명령은 살려서 그 단계의 `run`으로 옮긴다.
- verify의 검사는 명령마다 고르는 항목(`items`)으로 옮긴다. 명령은 prompt(`bouncer record`)로, run은 `bouncer passed`로 바꾼다.
- 나머지는 버리고 기본값에 맡긴다.
- 원본은 `workflow.yaml.bak`로 남는다.
