# workflow.yaml 스키마

## 이 파일이 하는 일

이 레포에서 "작업 끝"이라고 하려면 **통과해야 할 검사**를 적는다.
단계 순서(구현 → 검증 → 마무리)와 기본 규칙(검증 전 push 금지 등)은 전역 엔진의
기본값(`config/default.yaml`)에 있다. 레포 파일 `<레포>/.claude/ai-bouncer/workflow.yaml` 에는
**기본값과 다른 것만** 적는다. 비어 있으면(`version: 1` 한 줄) 기본값 그대로다.

보통은 verify 단계에 검사 명령 하나면 된다. 엔진이 직접 돌려 종료코드로 판정한다:

```yaml
version: 1
stages:
  verify:
    steps:
      - label: 테스트
        run: "npm test"
        blocking: true
```

자주 쓰는 것은 여기까지다(2026-10-24 기준 30개 레포 중 23곳은 비어 있고, 나머지도 `run`·`timeout`·`blocking`·`optional`·`inject` 정도만 쓴다).
아래는 전체 키 목록이다.

### 기본값과 합치는 규칙

| 키 | 규칙 |
|---|---|
| `settings` | 키 단위로 덮는다 |
| `workflows.<이름>` | 같은 이름이면 `label`·`stages` 를 덮고, 새 이름이면 추가 |
| `stages.<이름>.steps` | `label` 이 같으면 그 자리에서 교체, 새 `label` 이면 기본 step 뒤에 추가. `remove: [label…]` 로 기본 step 삭제 |
| `stages.<이름>.forbid` | 키 단위로 덮는다(`push: false` 로 기본 금지를 끌 수 있다) |
| `stages.<이름>.on_fail` | 적으면 덮는다 |
| 루트 `base: none` | 기본값 없이 이 파일 하나만 쓴다 |

## 최상위

| 키 | 설명 |
|---|---|
| `version` | 현재 `1` |
| `settings` | 엔진 숫자 설정. 거의 바꿀 일이 없다 (맨 아래 `settings` 절) |
| `workflows` | 시작할 때 뜨는 모드 선택지 |
| `stages` | 스테이지 정의. 체인에 쓰인 이름은 기본값과 합친 뒤 **전부** 정의돼야 한다 |

## `workflows.<이름>`

| 키 | 필수 | 설명 |
|---|:---:|---|
| `label` | ✅ | 모드 선택지에 표시될 설명 |
| `stages` | ✅ | 진행 순서 배열. 마지막이 종단 |

## `stages.<이름>` — 키 3개

| 키 | 값 | 설명 |
|---|---|---|
| `steps` | 리스트 | 이 단계에서 할 일. 순서 보장 |
| `forbid` | 매핑 | 이 단계에 머무는 동안 금지되는 것 |
| `on_fail` | 앞선 스테이지 \| `abort` | blocking 실패가 누적되면 되돌아갈 곳 |

> `edit_files: true` 인 스테이지는 제자리 수정이 불가능하므로 `max_attempts` 를
> 무시하고 1회 실패로 반송한다.

> `on_fail` 은 **실제로 실패한 조건**(`run` 게이트 등)이 있을 때 발동한다.
> `inject` + `blocking`(true/done)이 아직 done 표시가 안 된 것은 실패가 아니라
> 진행 중이므로 반송에 세지 않는다. plan 승인 대기도 반송하지 않는다.

> `on_fail` 왕복은 `max_loops`(기본 3)로 제한된다. 두 단계를 오가기만 하고
> 조건이 계속 안 맞으면 더 밀지 않고 사용자에게 판단을 넘긴다.

## `steps` 항목

| 키 | 필수 | 기본 | 설명 |
|---|:---:|---|---|
| `label` | △ | | `blocking`·`optional` 있으면 필수. step id의 근거 |
| `inject` / `inject_file` / `run` | ✅ | | **정확히 하나** |
| `by` | | `model` | `run` 전용. 누가 실행하나 |
| `timeout` | | model 600 / engine 30 | `run` 전용 (초) |
| `blocking` | | | 통과 조건 |
| `optional` | | `false` | 시작할 때 `--off` 로 끌 수 있다. **켜져 있으면 게이트다** — 실패해도 건너뛰지 않는다. 환경 탓에 실패할 수 있으면 `run` 안에서 준비(예: venv 생성)까지 하게 써라 |

`inject_file`은 config 디렉토리 기준 상대경로다. 내용은 컴파일 시점에 읽혀
`workflow.compiled.json`에 박히므로 런타임 파일 I/O가 없다.
프롬프트 파일만 고쳐도 해시가 바뀌어 재컴파일된다.

### `run`의 `{scope}` 자리

`run` 명령에 `{scope}` 를 넣으면 작업마다 돌릴 범위를 좁힐 수 있다. 단일 명령이면 자리 없이도 된다.

```yaml
- label: e2e
  run: "npx playwright test --workers=1 --reporter=line {scope}"
  blocking: true
```

- 모델이 `bouncer scope <step-id> <경로…>` 로 이번 작업이 새로 만들었거나 영향받는 테스트를 적는다.
- `bouncer run` 은 `{scope}` 를 그 경로들(하나씩 따옴표)로 바꿔 실행한다. 적은 게 없으면 빈칸이 되어 전체를 돌린다.
- `{scope}` 가 없어도 `npx playwright test --workers=1` 처럼 **단일 명령**이면 경로를 명령 끝에 붙인다.
- `a && b`·`;`·`|`·리다이렉트·치환이 든 명령은 붙일 곳을 모르니 `{scope}` 자리가 있어야 한다. 없으면 `bouncer scope` 가 거부한다.
- 범위 없이 전체를 돌려 실패하면, 무관한 실패일 때 범위로 좁히라고 Stop 이 안내한다.
- 경로만 받는다. `-` 로 시작하는 인자와 없는 경로는 거부한다. `tests/a.spec.ts:42` 처럼 줄 번호는 붙일 수 있다.
- 범위를 바꾸면 그 step의 통과 기록은 지워진다. 다시 돌려야 한다.
- 범위는 state.json `scope` 에 남는다. `bouncer status` 가 step마다 보여 준다.

### `by`

| 값 | 실행 주체 | 시간 제약 | 용도 |
|---|---|---|---|
| `model` (기본) | 모델이 `bouncer run <id>`로 실행. 명령은 엔진이 소유 | step의 `timeout`만 (기본 600초) | 테스트·빌드·e2e |
| `engine` | Stop hook 안에서 엔진이 실행 | **60초 상한 (컴파일 강제)** | 1초짜리 상태 확인 |

> `by: engine`에 60초 넘는 `timeout`을 주면 컴파일이 거부한다. hook이 타임아웃되면
> 판정 없이 워크플로우가 멈추기 때문이다.

### `blocking`

| 값 | 적용 | 판정 주체 | 모델 위조 |
|---|---|---|:---:|
| (없음) | 둘 다 | — | 강제 안 함 |
| `true` | `run` | 실제 종료코드 | 불가 |
| `true` | `inject` | 모델의 `bouncer done` (`done`과 같다 — 사람 확인 게이트는 없앴다) | 가능 — 자기신고 |
| `done` | `inject` | 모델의 `bouncer done` (사람 턴 불필요) | 가능 — 자기신고. 사람을 기다리지 않고 끝까지 진행시키는 용도. 미표시는 실패가 아니라 진행 중으로 보고 `on_fail` 반송에 세지 않는다 |
| `plan_approved` | `inject` | PostToolUse가 ExitPlanMode 승인 관찰 | 불가 |
| `skill:<이름>` | `inject` | PostToolUse가 스킬 호출 관찰 | 불가 |

플러그인 스킬처럼 이름에 `:`가 들어가는 경우도 그대로 쓴다 — `skill:telegram:access`.

뒤의 셋은 `inject` 전용이다. `run`에 쓰면 컴파일이 거부한다.

## `forbid`

| 키 | 값 | 막는 것 |
|---|---|---|
| `edit_files` | `true` \| glob 배열 | Edit/Write/MultiEdit/NotebookEdit **+ bash 우회**(`>`, `tee`, `sed -i`, `rm`, `mv`, `cp`, `touch`). `true` 는 실행 뒤 작업 트리 변경까지 본다 |
| `push` | `true` | `git push` 계열(`send-pack`·`svn dcommit` 포함). `gh pr create` 같은 다른 도구는 보지 않는다 |
| `bash` | 정규식 배열 | 임의 명령 (탈출구) |
| `reason` | 문자열 | **필수** — 차단당한 모델에게 표시 |

glob 배열은 `!` 접두로 예외를 만든다: `["**", "!docs/**"]` — 뒤에 오는 패턴이 이긴다.
Edit/Write 게이트와 셸 게이트는 **같은 판정기**를 쓴다. 다만 셸은 명령 안의
`cd` 를 따라가므로, 같은 상대경로라도 이동 뒤에는 다른 파일을 가리킬 수 있다
(절대경로로 주면 두 경로의 답은 언제나 같다).

| 패턴 | 뜻 |
|---|---|
| `*` | `/` 를 넘지 않는다. `src/*` 는 `src/a.js` 에 맞고 `src/deep/c.js` 에는 안 맞는다 |
| `**` | `/` 를 넘는다. `src/**` 는 `src` 자신과 그 아래 전부 |
| `!패턴` | 예외. 나중에 나온 패턴이 앞엣것을 덮는다 |

경로는 **프로젝트 루트 기준**으로 맞춘다 (세션 cwd가 아니다 — 하위 디렉토리에서
연 세션도 같은 규칙이 적용된다). 프로젝트 밖 경로(`/tmp/…`)는 스코프의 관심사가 아니다.

`true` 와 글로브 배열은 셸에 대한 강도가 다르다:

| 값 | Edit/Write | Bash |
|---|---|---|
| `true` | 작업 트리 안 차단 | **작업 트리 수정만 차단** — 명령 실행은 자유, 실행 뒤 트리가 바뀌면 잡는다 |
| 글로브 배열 | 스코프대로 | 임의 명령 실행 가능. **스코프에 걸린 경로에 쓰는 것만** 차단 |

`true` 모드가 막는 것은 **프로젝트 작업 트리(추적 파일 + 무시되지 않은 새 파일) 수정**뿐이다.

- 허용: 도구·브라우저 설치(`playwright install`), `npm`/`npx`/테스트 실행, 캐시·`/tmp`·다른 레포 쓰기,
  `.gitignore` 된 산출물(`test-results/`, `dist/`) 쓰기, 변수 대입·서브셸·반복문 같은 셸 문법.
- 사전 차단: 작업 트리 파일로의 Edit/Write, **기존 파일**을 향한 리다이렉트·`rm`/`cp`/`sed -i` 처럼
  대상이 보이는 쓰기, git 쓰기 서브커맨드, `~/.claude`·엔진 파일.
- 셸로 **새 파일·디렉토리**를 만드는 것(`mkdir`, `> new.txt`, `cp x new.js`)과 `git add`·`git commit`·
  `git archive` 는 사전에 막지 않는다. 트리가 바뀌면 사후 감지가 잡는다(2026-10-22 재생: 오탐 7건).
- 사후 감지: 단계에 들어올 때 작업 트리를 git tree 로 찍어두고(`ro_base`), Bash 실행 뒤마다
  (PostToolUse / PostToolUseFailure) 다시 찍어 비교한다. 달라졌으면 바뀐 경로를 알리고,
  Stop 도 되돌릴 때까지 단계를 끝내지 못하게 한다.
- `bouncer restore` — 진입 시점으로 되돌린다. 구현 단계에서 만든 미커밋 변경은 그대로 두고,
  이 단계에서 생긴 변경만 되돌린다. 진짜 인덱스는 건드리지 않는다. `.claude/` 는 비교에서 뺀다.

반송(`on_fail`)으로 구현 단계에 돌아온 뒤 작업 트리가 그대로여도, 그 사이 도구를 썼다면
(지워진 브라우저 캐시 재설치 같은 환경 정리) 다시 검증에 보낸다. 도구를 하나도 안 썼으면 예전처럼 막는다.

배열 모드는 `npm test`·`./build.sh` 처럼 무엇을 쓰는지 확정할 수 없는 명령을 통과시킨다.
셸 문법만으로는 알 수 없기 때문이다 — 이건 가드레일이지 샌드박스가 아니다.
확실히 막아야 하면 `edit_files: true` 를 쓰고, 검증 명령은 `run:` 스텝으로 등록해라.

### 판정기가 보장하지 못하는 것

감사에서 실제로 확인된 한계다. 알고 쓰라고 적어둔다.

- **배열 모드·push 모드에서 임의 스크립트를 실행하면 무엇이든 할 수 있다.**
  `./build.sh` 안에서 스코프 밖 파일을 고치거나 `.ai-bouncer/` 를 지워도 판정기는 모른다.
  스크립트 실행 자체를 허용하는 게 이 모드의 목적이라 구분할 방법이 없다.
- 그래서 **엔진 파일 보호도 절대적이지 않다.** 직접 명령(`rm -rf .ai-bouncer`,
  `find -delete`, 코드 문자열에 엔진 경로가 든 `sh -c`, 심볼릭 링크)은 막지만, 스크립트 안까지는 못 본다.
- **push·쓰기를 숨기는 형태는 사전에 막지 않는다** (`bash -c`, `eval`, `source`, `env -S`,
  명령 이름 자리 치환, `PATH=`·`LD_PRELOAD=`·`GIT_*` 접두, git 별칭). 모델은 숨기려 하지 않는다 —
  실사용 차단 47건이 전부 정상 명령이었고 숨긴 push·쓰기는 0건이었다(2026-10-22 감사).
  잡는 것은 그대로 적힌 `git push`(인라인 코드 안 포함)와 실행 뒤 작업 트리 비교다.
- `edit_files: true` 모드도 임의 명령을 실행할 수 있다. 다만 작업 트리 변경은 실행 뒤
  스냅샷 비교로 반드시 드러나고 Stop 이 통과시키지 않는다. 트리 밖(엔진 상태, push)은 같은 한계가 있다.

> PreToolUse는 타임아웃되면 차단이 **아예 안 된다**(공식 문서: *"don't count on a
> stalled hook to act as a gate"*). 그래서 이 검사는 `jq` 한 번만 하고 명령을 실행하지 않는다.

> `blocking: checklist` 는 자기보고가 아니다 — `bouncer todo` 로 세운 항목을
> **엔진이 센다.** 목록이 비었거나 남은 항목이 있으면 통과하지 않고,
> 세운 직후 같은 턴에 전부 체크해도 통과하지 않는다(사용자가 한 번은 봐야 한다).
> 뺀 항목은 `dropped` 에 남아 조용히 사라지지 않는다.

## state.json 필드

| 필드 | 누가 쓰나 | 뜻 |
|---|---|---|
| `current_stage` | Stop hook | 지금 단계. CLI로 바꿀 수 없다 |
| `evidence` | Stop / PostToolUse | step별 통과 증거 |
| `evidence_tree` | `bouncer run` / Stop | `run` step 이 통과한 시점의 추적 파일 내용 지문. 커밋·추적 안 된 산출물로는 안 바뀐다. 이후 추적 파일 내용이 달라지면 Stop 이 그 통과를 무효로 돌린다 |
| `shown` | Stop | 이미 전달한 inject |
| `choices` | `start --off` | optional step의 on/off |
| `scope` | `bouncer scope` | `{scope}` 자리가 있는 step별 이번 작업 범위(경로 목록). 없으면 전체 |
| `skipped` | `bouncer skip` | 엔진이 포기한 뒤 이번 작업만 면제한 step |
| `plan` | PostToolUse | 승인된 계획 원문 (plan 모드) |
| `checklist` | `bouncer todo` / 계획 승인 | 할 일 목록. `blocking: checklist` 가 **엔진이 세서** 판정한다 |
| `checklist_turn` | `bouncer todo` | 목록을 마지막으로 고친 시점의 사용자 턴 수. 세우자마자 전부 체크하는 것을 막는다 |
| `dropped` | `bouncer todo drop` | 범위에서 뺀 항목. 조용히 사라지지 않게 남긴다 |
| `skip_allowed` | Stop | 엔진이 포기하며 **제안한 step id 목록**. `bouncer skip` 은 여기 있는 것만 열어주고, 쓰면 그 id 를 소모한다 |
| `stage_attempts` | Stop | on_fail 반송 판단용 시도 횟수 |
| `loops` | Stop | 스테이지 쌍별 왕복 횟수 (`max_loops`) |
| `continue_streak` / `blocks_total` | Stop | 무한 차단 방지 카운터 |
| `user_turns` / `user_turns_at_wait` | UserPromptSubmit / Stop | 사람이 실제로 답했는지 |
| `work_root` / `worktree` | `start --parallel` | 병렬 작업 트리 |
| `returned_to` / `returned_from` / `returned_tree` | Stop | on_fail 반송 기록 |

## 컴파일이 거부하는 것

| 상황 | 이유 |
|---|---|
| 마지막 스테이지에 `blocking` | 넘어갈 곳이 없어 작업이 끝나지 않고 잠금이 남는다. 여러 워크플로우가 스테이지를 공유하면 **어느 하나에서라도 마지막이면** 거부된다 |
| 체인에 정의 없는 스테이지 | 오타로 단계가 조용히 사라진다 |
| `on_fail`이 뒤쪽/체인 밖 | 되돌아가기만 허용 (무한 전진 방지) |
| `blocking`·`optional`인데 `label` 없음 | 진행 상태를 위치가 아닌 이름으로 추적 |
| `blocking` 값이 목록 밖 | `true` / `plan_approved` / `checklist` / `done` / `skill:<이름>` 외 |
| 같은 스테이지에 중복된 `label` | step id가 겹쳐 진행 기록이 엉킨다 |
| 한 체인에 같은 스테이지가 두 번 | |
| `version`이 1이 아님 | |
| 빈 `inject` | |
| `optional`이 boolean이 아님 | |
| `forbid.bash`의 정규식이 컴파일 안 됨 | |
| 알 수 없는 키 (root / workflows / stages / step / forbid 어디든) | 오타로 설정이 조용히 무시되는 것을 막는다 |
| `run`에 `plan_approved`·`skill:` | hook 관찰 방식이라 셸 명령엔 부적용 |
| `by`가 model/engine 아님 | |
| `by: engine` + timeout > 60초 | hook 타임아웃 → 판정 없이 정지 |
| `forbid`에 `reason` 없음 | 모델이 이유를 몰라 헤맨다 |
| `inject_file` 경로 없음 | 빈 프롬프트로 조용히 진행 |
| 고아 스테이지 | 어떤 워크플로우에도 안 쓰임 |
| 내장 파서 + YAML 앵커 | pyyaml 없는 머신에서 `stages`가 통째로 사라진다 |
| **같은 블록에 중복된 키** | YAML은 뒤엣것으로 조용히 덮어쓴다. `forbid:`를 실수로 두 번 쓰면 앞의 가드가 에러 없이 사라진다 |

> hook은 전역 `~/.claude/settings.json` 에 한 번만 등록된다. 레포에는 이 설정 파일만 있다.

## `settings`

기본값은 엔진 코드에 있다. yaml에는 바꾸고 싶은 것만 적으면 된다 —
새 설정이 생겨도 기존 yaml을 고칠 필요가 없다.

```yaml
settings:
  max_continue: 20
```

| 키 | 기본 | 설명 |
|---|---|---|
| `max_attempts` | `3` | blocking 실패 재시도 후 `on_fail` 발동 |
| `max_continue` | `10` | Stop 연속 차단 상한. 초과 시 사용자에게 질문 |
| `max_loops` | `3` | `on_fail`로 앞 단계와 왕복할 수 있는 횟수. 초과하면 사용자에게 넘긴다 |
| `stale_lock_hours` | `12` | 이 시간 넘게 하트비트가 멈춘 잠금을 정리 |

알 수 없는 키는 컴파일이 거부한다 (오타로 설정이 조용히 무시되는 것을 막는다).
폐기된 `update_branch`·`repo`·`update_check*` 는 오류 없이 무시하고, `bouncer init` 이 파일에서 걷어낸다.

