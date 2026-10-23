#!/usr/bin/env python3
# Edit/Write 대상이 엔진 파일(상태·설정·hook 등록)인지 판정한다.
# 이걸 고치면 모델이 단계를 스스로 넘기거나 hook 을 끌 수 있다.
#
# 셸 명령은 보지 않는다. 7일 차단 76건 중 state/.active 를 실제로 겨눈 건 1건이고
# 나머지는 ls·sed·find 같은 읽기 오탐이었다(2026-10-23 감사).
#
#   guard.py --check-path <project> <파일경로> [cwd]
# 출력: 차단 사유 (없으면 허용)
import os
import sys

if len(sys.argv) < 4 or sys.argv[1] != '--check-path':
    sys.exit(0)


def _real(p):
    """심볼릭 링크까지 푼 절대경로. 링크로 우회하는 경로를 같은 이름으로 모은다."""
    try:
        return os.path.realpath(p) if p else ''
    except (OSError, ValueError):
        return os.path.normpath(p) if p else ''


PROJECT = _real(sys.argv[2])
TARGET = sys.argv[3]
CWD = _real(sys.argv[4] if len(sys.argv) > 4 else '') or PROJECT

# 엔진 소유 경로. 부분문자열이 아니라 **경로 성분**으로 본다.
ENGINE_DIRS = (('.ai-bouncer',), ('.claude', 'ai-bouncer'))
ENGINE_FILES = ('workflow.compiled.json',)
# settings.json 은 hook 등록을 담는다. 여기서 등록을 지우면 게이트가 통째로 사라진다.
ENGINE_SETTINGS = ('.claude', 'settings.json')

ENGINE_MSG = ("엔진 파일(.ai-bouncer/ 상태, .claude/ai-bouncer/ 설정·엔진, "
              "workflow.compiled.json)은 직접 수정할 수 없다.\n"
              "읽는 것은 자유다 — `cat`/`ls`/`grep` 으로 확인해라.\n"
              "작업 상태를 바꾸려면 `bouncer` 명령을 써라.")


def abspath(p):
    """절대경로로 편다. 상위 디렉토리와, 링크라면 마지막 성분까지 푼다 —
    `src/s -> ../.ai-bouncer/…` 를 타고 보호 대상을 덮어쓰지 못하게."""
    p = os.path.expanduser(p.strip('"\''))
    if not p:
        return ''
    base = p if os.path.isabs(p) else os.path.join(CWD, p)
    head, tail = os.path.split(os.path.normpath(base))
    if not tail:
        return _real(base)
    full = os.path.normpath(os.path.join(_real(head) or head, tail))
    try:
        if os.path.islink(full):
            return _real(full)
    except (OSError, ValueError):
        pass
    return full


def _has(parts, want):
    n = len(want)
    return any(tuple(parts[i:i + n]) == want for i in range(len(parts) - n + 1))


def is_engine_path(tok):
    a = abspath(tok)
    # 프로젝트 밖의 동명 디렉토리까지 막으면 근거 없는 차단이 된다.
    if not a or not PROJECT or not (a == PROJECT or a.startswith(PROJECT + '/')):
        return False
    parts = a[len(PROJECT):].lstrip('/').split('/')
    if tuple(parts[-2:]) == ENGINE_SETTINGS or parts[-1] in ENGINE_FILES:
        return True
    return any(_has(parts, want) for want in ENGINE_DIRS)


if is_engine_path(TARGET):
    sys.stdout.write(ENGINE_MSG)
