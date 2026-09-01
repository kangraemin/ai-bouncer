#!/usr/bin/env python3
"""셸 명령이 이 스테이지에서 허용되는지 판정한다.

두 번의 감사에서 블랙리스트 방식이 양쪽으로 졌다 —
`X=1 rm -f a`, `{ rm -f a; }`, `$(rm f)`, `curl -o`, `git -c alias.p=push p` 로 뚫리는 동시에
`find`, `awk`, `git log --format="%h -> %s"`, `npm test > /dev/null` 을 잘못 막았다.

그래서 뒤집었다:
  · 토큰화는 shlex(punctuation_chars=True) — 따옴표 안의 `>`는 그대로 두고
    진짜 연산자만 분리한다. `1> f` 의 fd 접두도 보인다.
  · edit_files 를 금지한 스테이지는 **읽기 전용 허용 목록**으로 판정한다.
    무엇이 쓰는지 열거하는 대신 무엇이 안 쓰는지만 인정한다.
  · 그 스테이지에서 검증 명령을 돌려야 하면 `bouncer run <id>` 를 쓴다 —
    명령을 엔진이 소유하므로 임의 셸을 열어줄 이유가 없다.

stdin: 명령 문자열
argv:  <edit_files_json> <push_bool> <bash_patterns_json> <project_dir>
출력:  차단 사유 (없으면 빈 출력 = 허용)
"""
import json
import os
import re
import shlex
import sys

CMD = sys.stdin.read()
EDIT = json.loads(sys.argv[1])
PUSH = sys.argv[2] == "true"
PATTERNS = json.loads(sys.argv[3])
PROJECT = sys.argv[4]

# 파일을 쓰지 않는 것으로 확인된 명령만. 여기 없으면 막는다.
READ_ONLY = {
    'ls', 'cat', 'head', 'tail', 'wc', 'file', 'stat', 'pwd', 'echo', 'printf',
    'basename', 'dirname', 'realpath', 'readlink', 'du', 'df', 'tree', 'which',
    'type', 'date', 'whoami', 'uname', 'hostname', 'id', 'true', 'false', 'test',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'fd', 'locate',
    'diff', 'cmp', 'comm', 'uniq', 'cut', 'tr', 'column', 'nl', 'rev', 'tac',
    'fold', 'expand', 'paste', 'join', 'xxd', 'od', 'strings', 'less', 'more',
    'jq', 'xmllint', 'base64', 'shasum', 'md5sum', 'sha256sum', 'seq', 'yes',
    'sort', 'find', 'sed', 'awk', 'gawk', 'git',   # 아래에서 인자를 따로 본다
}
# git 중 읽기만 하는 서브커맨드
GIT_READ = {
    'status', 'log', 'diff', 'show', 'branch', 'tag', 'rev-parse', 'rev-list',
    'ls-files', 'ls-tree', 'ls-remote', 'blame', 'describe', 'cat-file',
    'shortlog', 'whatchanged', 'reflog', 'grep', 'count-objects', 'var',
    'symbolic-ref', 'name-rev', 'merge-base', 'check-ignore', 'diff-tree',
}
OPERATORS = {';', '&', '&&', '||', '|', '>', '>>', '<', '<<', '(', ')', '{', '}',
             '$', '`', ';;', '|&', '<(', '>(', '>|', '&>', '&>>', '<<<', '<>'}
# 토큰 안에 리다이렉트 기호가 섞여 나오는 경우(`>|`, `2>&1` 등)도 잡는다
REDIR_IN_TOKEN = re.compile(r'^[0-9]*(>{1,2}\|?|<{1,3}|&>{1,2})$')

ENGINE_PARTS = ('.ai-bouncer/tasks', 'workflow.compiled.json', '.claude/ai-bouncer')


def out(msg):
    sys.stdout.write(msg)
    sys.exit(0)


def tokenize(cmd):
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    try:
        return list(lx)
    except ValueError:
        return None


def norm(p):
    """`docs/../a.js` 를 `a.js` 로. 정규화 없이 비교하면 스코프가 그냥 뚫린다."""
    p = p.strip('"\'')
    if p.startswith(PROJECT + '/'):
        p = p[len(PROJECT) + 1:]
    return os.path.normpath(p).lstrip('./') or '.'


def glob_re(pat):
    """`**` 는 구분자를 넘고 `*` 는 넘지 않는다. fnmatch 는 이 구분이 없다."""
    i, out_ = 0, ['^']
    while i < len(pat):
        c = pat[i]
        if pat.startswith('**/', i):
            out_.append('(?:.*/)?'); i += 3
        elif pat.startswith('**', i):
            out_.append('.*'); i += 2
        elif c == '*':
            out_.append('[^/]*'); i += 1
        elif c == '?':
            out_.append('[^/]'); i += 1
        else:
            out_.append(re.escape(c)); i += 1
    out_.append('$')
    return re.compile(''.join(out_))


def path_forbidden(p):
    if EDIT is None:
        return False
    if EDIT is True:
        return True
    rel, hit = norm(p), False
    for pat in EDIT:
        neg = pat.startswith('!')
        if glob_re(pat[1:] if neg else pat).match(rel):
            hit = not neg
    return hit


TOKENS = tokenize(CMD)
if TOKENS is None:
    out("따옴표가 닫히지 않아 명령을 판정할 수 없다.")

# ── 엔진 파일은 스테이지와 무관하게 항상 보호한다 ──────────────
raw_norm = CMD.replace('\\', '/')
if any(part in raw_norm for part in ENGINE_PARTS) or \
   any(part in norm(t) for t in TOKENS for part in ENGINE_PARTS):
    first = TOKENS[0] if TOKENS else ''
    if os.path.basename(first.strip('"\'')) not in ('bouncer', 'bouncer.sh'):
        out("엔진 파일(state.json / .active / workflow.compiled.json / .claude/ai-bouncer/)은 "
            "직접 다룰 수 없다.")

# ── bouncer 자신은 통째로 허용 (게이트를 통과할 유일한 수단) ────
# 단 연산자가 섞이면 뒤에 다른 명령을 붙인 것이므로 아래 규칙으로 넘어간다.
if TOKENS and os.path.basename(TOKENS[0].strip('"\'')) in ('bouncer', 'bouncer.sh') \
   and not (set(TOKENS) & OPERATORS):
    sys.exit(0)


def commands(tokens):
    """파이프로만 나눈다. 다른 연산자는 이 앞에서 이미 거부된다."""
    cur, res = [], []
    for t in tokens:
        if t == '|':
            res.append(cur); cur = []
        else:
            cur.append(t)
    res.append(cur)
    return [c for c in res if c]


def git_sub(toks):
    i = 1
    while i < len(toks):
        t = toks[i]
        if t in ('-C', '--git-dir', '--work-tree', '--namespace', '--exec-path'):
            i += 2; continue
        if t == '-c':
            return None          # -c 로 alias 를 심을 수 있다 — 판정 불가로 본다
        if t.startswith('-'):
            i += 1; continue
        return t
    return None


if EDIT is not None:
    # ── 읽기 전용 스테이지 ────────────────────────────────────
    bad = ((set(TOKENS) & OPERATORS) - {'|'}) \
          | {t for t in TOKENS if t != '|' and REDIR_IN_TOKEN.match(t)}
    if bad:
        out("이 단계는 읽기 전용이다. 셸 연산자(%s)는 쓸 수 없다 — "
            "무엇을 하는 명령인지 확인할 수 없기 때문이다.\n"
            "검증 명령을 돌려야 하면 `bouncer run <step-id>` 를 써라."
            % ' '.join(sorted(bad)))

    for cmd in commands(TOKENS):
        exe = os.path.basename(cmd[0].strip('"\'').lstrip('\\'))
        if '=' in cmd[0] and not cmd[0].startswith('-'):
            out("이 단계는 읽기 전용이다. 환경변수를 붙인 명령(%s)은 쓸 수 없다." % cmd[0])
        if exe in ('bouncer', 'bouncer.sh'):
            continue
        if exe not in READ_ONLY:
            out("이 단계는 읽기 전용이다. `%s` 는 파일을 쓸 수 있어 허용되지 않는다.\n"
                "읽기·검색은 가능하고, 검증 명령은 `bouncer run <step-id>` 로 실행한다." % exe)
        # 읽기 전용 목록에 있어도 쓰기 모드가 따로 있는 것들
        if exe == 'sed' and any(a == '-i' or a.startswith('-i') for a in cmd[1:]):
            out("`sed -i` 는 파일을 직접 고친다. 이 단계에서는 허용되지 않는다.")
        if exe == 'sort' and '-o' in cmd[1:]:
            out("`sort -o` 는 파일을 쓴다. 이 단계에서는 허용되지 않는다.")
        if exe == 'find' and any(a in ('-exec', '-execdir', '-delete', '-ok', '-okdir')
                                 for a in cmd[1:]):
            out("`find -exec/-delete` 는 임의 명령을 실행한다. 이 단계에서는 허용되지 않는다.")
        if exe in ('awk', 'gawk') and any('>' in a for a in cmd[1:]):
            out("awk 프로그램 안의 리다이렉트는 파일을 쓴다. 이 단계에서는 허용되지 않는다.")
        if exe == 'git':
            sub = git_sub(cmd)
            if sub is None:
                out("이 git 명령이 무엇을 하는지 판정할 수 없다 (`-c` 등). "
                    "읽기 명령은 그대로 쓰고, 그 외에는 단계를 넘긴 뒤에 하라.")
            if sub not in GIT_READ:
                out("`git %s` 는 읽기 명령이 아니다. 이 단계에서는 허용되지 않는다." % sub)
        # 경로 스코프가 있으면 대상 경로도 확인한다
        if EDIT is not True and exe in ('sed', 'sort', 'find'):
            for a in cmd[1:]:
                if not a.startswith('-') and path_forbidden(a):
                    out("`%s` 로 %s 를 다룰 수 없다." % (exe, a))

elif PUSH:
    # ── push 만 금지된 스테이지 ───────────────────────────────
    for cmd in commands([t for t in TOKENS if t not in OPERATORS]):
        exe = os.path.basename(cmd[0].strip('"\'').lstrip('\\')) if cmd else ''
        if exe == 'git-push':
            out("push가 차단되었다.")
        if exe == 'git':
            sub = git_sub(cmd)
            if sub is None:
                out("`git -c ...` 는 별칭으로 push를 숨길 수 있어 이 단계에서는 허용되지 않는다.")
            if sub == 'push':
                out("push가 차단되었다.")
            if sub == 'config' and any('alias.' in a for a in cmd):
                out("이 단계에서 git 별칭을 등록할 수 없다 (push를 숨길 수 있다).")

for pat in PATTERNS:
    try:
        if re.search(pat, CMD):
            out("차단된 명령이다: %s" % CMD[:80])
    except re.error:
        pass
