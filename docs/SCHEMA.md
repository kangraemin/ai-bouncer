# workflow.yaml 스키마

## 최상위

| 키 | 필수 | 설명 |
|---|:---:|---|
| `version` | ✅ | 현재 `1` |
| `settings` | | 엔진 설정. 적지 않으면 기본값 |
| `workflows` | ✅ | 시작할 때 뜨는 모드 선택지 |
| `stages` | ✅ | 스테이지 정의. 체인에 쓰인 이름은 **전부** 정의돼야 한다 |

설정 파일은 이것 하나다. 별도 `config.json`은 없고, 설치는 **프로젝트별로만** 한다
(`<프로젝트>/.claude/ai-bouncer/workflow.yaml`). 전역 설치는 지원하지 않는다.

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
> 무시하고 1회 실패로 반송한다. 단 사람 확인 게이트가 함께 미충족이면
> 답할 기회를 줘야 하므로 그 즉시 반송은 하지 않는다.

> `on_fail` 은 **사람과 무관한 조건이 실패했을 때** 발동한다. 사람 확인
> (`inject` + `blocking: true`)만 미충족이면 답할 기회를 줘야 하므로 반송하지
> 않는다. 같은 스테이지에 `run` 게이트가 있고 그것이 실패했다면 반송한다.

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
| `optional` | | `false` | 시작할 때 할지 말지 물어봄 |

`inject_file`은 config 디렉토리 기준 상대경로다. 내용은 컴파일 시점에 읽혀
`workflow.compiled.json`에 박히므로 런타임 파일 I/O가 없다.
프롬프트 파일만 고쳐도 해시가 바뀌어 재컴파일된다.

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
| `true` | `inject` | 사용자 턴 발생 + `bouncer done` | 불가 |
| `plan_approved` | `inject` | PostToolUse가 ExitPlanMode 승인 관찰 | 불가 |
| `skill:<이름>` | `inject` | PostToolUse가 스킬 호출 관찰 | 불가 |

플러그인 스킬처럼 이름에 `:`가 들어가는 경우도 그대로 쓴다 — `skill:telegram:access`.

뒤의 셋은 `inject` 전용이다. `run`에 쓰면 컴파일이 거부한다.

## `forbid`

| 키 | 값 | 막는 것 |
|---|---|---|
| `edit_files` | `true` \| glob 배열 | Edit/Write/MultiEdit/NotebookEdit **+ bash 우회**(`>`, `tee`, `sed -i`, `rm`, `mv`, `cp`, `touch`) |
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
| `true` | 전부 차단 | **전면 읽기 전용** — 허용 목록에 있는 조회 명령만. `npm test` 도 못 돈다 |
| 글로브 배열 | 스코프대로 | 임의 명령 실행 가능. **스코프에 걸린 경로에 쓰는 것만** 차단 |

배열 모드는 `npm test`·`./build.sh` 처럼 무엇을 쓰는지 확정할 수 없는 명령을 통과시킨다.
셸 문법만으로는 알 수 없기 때문이다 — 이건 가드레일이지 샌드박스가 아니다.
확실히 막아야 하면 `edit_files: true` 를 쓰고, 검증 명령은 `run:` 스텝으로 등록해라.

### 판정기가 보장하지 못하는 것

감사에서 실제로 확인된 한계다. 알고 쓰라고 적어둔다.

- **배열 모드·push 모드에서 임의 스크립트를 실행하면 무엇이든 할 수 있다.**
  `./build.sh` 안에서 스코프 밖 파일을 고치거나 `.ai-bouncer/` 를 지워도 판정기는 모른다.
  스크립트 실행 자체를 허용하는 게 이 모드의 목적이라 구분할 방법이 없다.
- 그래서 **엔진 파일 보호도 절대적이지 않다.** 직접 명령(`rm -rf .ai-bouncer`,
  `find -delete`, 셸 `sh -c`, 심볼릭 링크)은 전부 막지만, 스크립트 안까지는 못 본다.
- `edit_files: true` 모드는 허용 목록 방식이라 이 구멍이 없다.
  단계를 확실히 강제해야 하면 이쪽을 쓰고, 실행이 필요한 것은 `run:` 스텝으로 등록해라.

> PreToolUse는 타임아웃되면 차단이 **아예 안 된다**(공식 문서: *"don't count on a
> stalled hook to act as a gate"*). 그래서 이 검사는 `jq` 한 번만 하고 명령을 실행하지 않는다.

## state.json 필드

| 필드 | 누가 쓰나 | 뜻 |
|---|---|---|
| `current_stage` | Stop hook | 지금 단계. CLI로 바꿀 수 없다 |
| `evidence` | Stop / PostToolUse | step별 통과 증거 |
| `shown` | Stop | 이미 전달한 inject |
| `choices` | `start --off` | optional step의 on/off |
| `skipped` | `bouncer skip` | 엔진이 포기한 뒤 이번 작업만 면제한 step |
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
| `blocking` 값이 목록 밖 | `true` / `plan_approved` / `skill:<이름>` 외 |
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

> hook은 `<프로젝트>/.claude/settings.json`에 `${CLAUDE_PROJECT_DIR}` 기준 경로로 등록된다.
> 절대경로가 아니므로 이 파일을 팀과 공유해도 다른 컴퓨터에서 깨지지 않는다.

## `settings`

기본값은 엔진 코드에 있다. yaml에는 바꾸고 싶은 것만 적으면 된다 —
새 설정이 생겨도 기존 yaml을 고칠 필요가 없다.

```yaml
settings:
  update_branch: dev
  max_continue: 20
```

| 키 | 기본 | 설명 |
|---|---|---|
| `update_branch` | `main` | 자동 업데이트 기준 브랜치 |
| `update_check` | `true` | 업데이트 확인 on/off |
| `update_check_interval_hours` | `6` | 확인 주기 |
| `max_attempts` | `3` | blocking 실패 재시도 후 `on_fail` 발동 |
| `max_continue` | `10` | Stop 연속 차단 상한. 초과 시 사용자에게 질문 |
| `max_loops` | `3` | `on_fail`로 앞 단계와 왕복할 수 있는 횟수. 초과하면 사용자에게 넘긴다 |
| `stale_lock_hours` | `12` | 이 시간 넘게 하트비트가 멈춘 잠금을 정리 |
| `repo` | `kangraemin/ai-bouncer` | 업데이트를 받아올 저장소 |

알 수 없는 키는 컴파일이 거부한다 (오타로 설정이 조용히 무시되는 것을 막는다).

