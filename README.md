# ai-bouncer

Claude Code가 개발 작업을 **선언적으로 정의한 스테이지 체인**대로 진행하도록 강제하는 hook 엔진.

기존 버전은 워크플로우가 hook 코드에 하드코딩돼 있었다. 이번 버전은 워크플로우가
**데이터(`workflow.yaml`)** 이고, hook은 그걸 읽어 동작하는 범용 엔진이다.

```yaml
workflows:
  plan:
    label: 계획을 세우고 승인받은 뒤 구현
    stages: [plan, implement, verify, finalize, done]

stages:
  verify:
    on_fail: implement              # 막히면 구현 단계로 되돌아감
    steps:
      - label: 유닛 테스트
        run: "npm test -- --run"
        blocking: true              # 통과 못 하면 다음 단계로 못 감
    forbid:
      push: true
      reason: 검증 전에는 push할 수 없다.
```

## 설치

```bash
git clone https://github.com/kangraemin/ai-bouncer
cd <설치할-프로젝트>
bash <클론경로>/install.sh                # 이 프로젝트에 설치
bash <클론경로>/install.sh --branch dev   # 업데이트 기준 브랜치 지정
```

설치는 **프로젝트별로만** 한다. 레포마다 워크플로우가 다른 게 정상이고,
전역을 두면 "어느 설정이 이겼나"를 매번 따져야 하기 때문이다.

설치되는 것:

```
<프로젝트>/
├── .claude/
│   ├── ai-bouncer/
│   │   ├── workflow.yaml          ← 유일한 설정 파일. 이것만 고치면 된다
│   │   ├── prompts/plan.md
│   │   ├── engine/ hooks/ scripts/
│   │   └── workflow.compiled.json ← 자동 생성 (gitignore)
│   ├── settings.json              ← hook 5개 등록 (남의 hook은 건드리지 않는다)
│   └── skills/dev-bounce/
├── .ai-bouncer/                   ← 런타임 상태 (gitignore)
└── .gitignore                     ← .ai-bouncer/ 자동 추가
```

제거: `./uninstall.sh` (워크플로우와 진행 중 작업은 남는다) / `--purge` (전부 삭제)

구버전에서 올라오면 install이 구 hook 7개와 구 파일을 자동으로 정리하고,
읽을 수 없는 구 작업(`.ai-bouncer-tasks/`)이 남아 있으면 알려준다.

## 쓰는 법

세션에서 `/dev-bounce`를 실행하면 모드를 고르고 작업이 시작된다.
이후에는 엔진이 단계마다 지시를 주입하고, 조건을 충족해야 다음 단계로 넘어간다.

```bash
bouncer status                 # 현재 단계와 남은 조건
bouncer check                  # workflow.yaml을 고친 뒤 유효한지 검사
bouncer run <step-id>          # 검증 명령 실행 (명령은 엔진이 소유한다)
bouncer done <step-id>         # 사람 확인이 필요한 항목 완료 처리
bouncer worktree create        # 병렬 작업 — 별도 브랜치 + 레포 밖 worktree
bouncer worktree finalize      # base로 rebase → FF 머지 → 정리
```

## 설계 원칙

1. **워크플로우는 데이터다.** 스테이지 추가·삭제·순서변경은 yaml 편집으로 끝난다.
   엔진 코드는 건드리지 않는다.
2. **`current_stage`의 유일한 writer는 hook이다.** 모델은 단계를 스스로 넘길 수 없고,
   `state.json` 직접 수정은 차단된다.
3. **자기신고는 게이트가 아니다.** 통과 판정은 셋 중 하나로만 한다 —
   실제 종료코드, hook이 관찰한 도구 사용(`plan_approved` / `skill:`), 실제 사용자 턴.
4. **설정 파일은 하나다.** `workflow.yaml`에 설정·워크플로우가 다 들어간다.
   기본값은 코드에 있어서, 새 설정이 생겨도 기존 yaml을 고칠 필요가 없다.
5. **런타임 의존성은 `jq`뿐이다.** yaml은 설치·변경 시점에 json으로 컴파일된다.
   pyyaml이 없는 머신에서도 같은 결과가 나오도록 내장 파서를 함께 검증한다.
6. **상태는 `state.json` 하나다.** 별도 문서 트리·TC 파일 없음.
7. **fail-open 금지.** 오타난 스테이지 이름, 존재하지 않는 프롬프트 파일,
   해석이 갈리는 YAML 앵커는 전부 컴파일 단계에서 거부한다.

## 구성

| 경로 | 역할 |
|---|---|
| `config/default.yaml` | 기본 워크플로우. 설치 시 프로젝트로 복사되고 이후 보존된다 |
| `config/prompts/plan.md` | plan 단계 프롬프트 |
| `config/prompts/` | 긴 프롬프트 (`inject_file`로 참조) |
| `engine/compile.py` | yaml → compiled.json + 스키마 검증 |
| `engine/bouncer.sh` | CLI |
| `engine/lib/common.sh` | hook·CLI 공용 라이브러리 |
| `hooks/session-start.sh` | 재컴파일, 방치된 잠금 정리, 진행 중 작업 복원 |
| `hooks/pre-tool.sh` | `forbid` 강제 (가벼워야 한다 — 타임아웃되면 차단이 안 된다) |
| `hooks/post-tool.sh` | ExitPlanMode·Skill 관찰 |
| `hooks/stop.sh` | **엔진 본체** — step 수행, blocking 판정, 스테이지 전이 |
| `hooks/session-end.sh` | 자기 잠금만 해제 (예산 1.5초) |
| `skills/dev-bounce/` | 스킬 — 시작 절차만 담는다. 워크플로우 내용은 yaml에 있다 |
| `examples/` | 웹(Next.js)·앱(RN)·백엔드(Python) 실사용 config |
| `docs/SCHEMA.md` | 스키마 레퍼런스 |

## 테스트

```bash
bash tests/run-all.sh
```

케이스별로 나뉘어 있다 — plan/simple 전 구간, `on_fail` 되돌아가기, optional 건너뛰기,
`skill:` 게이트, 무한루프 상한, 다중 세션 격리, worktree 병렬·FF 머지,
`forbid` 경로 스코프, 컴파일 거부 12종, 파서 동등성, 방치 잠금 정리, 설치/제거.
