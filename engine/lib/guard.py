#!/usr/bin/env python3
# 셸 명령이 이 스테이지에서 허용되는지 판정한다.
#
# 세 차례 감사에서 배운 것:
#  · 블랙리스트(쓰는 명령 열거)는 원리상 완결되지 않는다.
#  · 그렇다고 허용 목록만으로도 부족하다 — 목록 안의 명령에도 쓰기 모드가 있다
#    (`sed …w out`, `sort --output=`, `xxd in out`, `git branch`).
#  · 그래서 (1) 허용 목록 (2) 출력 인자 차단 (3) 구조를 볼 수 없는 구문 거부 를 겹친다.
#  · 안을 볼 수 없는 것만 막으면 되므로 `;` `&&` `|` 는 허용한다 —
#    각 조각을 따로 판정하기 때문이다. 이게 과차단을 크게 줄인다.
#
# 이건 샌드박스가 아니라 가드레일이다. 진짜 보장은 blocking 게이트가 한다.
#
# stdin: 명령 문자열 / argv: <edit_files_json> <push_bool> <bash_patterns_json> <project_dir>
# 출력: 차단 사유 (없으면 허용)
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

# 파일을 쓰지 않는 것으로 확인된 명령만.
# awk/python/node/ruby/perl 은 system() 등으로 임의 명령을 실행할 수 있어 제외한다.
READ_ONLY = {
    'ls', 'cat', 'head', 'tail', 'wc', 'file', 'stat', 'pwd', 'echo', 'printf',
    'basename', 'dirname', 'realpath', 'readlink', 'du', 'df', 'tree', 'which',
    'type', 'date', 'whoami', 'uname', 'hostname', 'id', 'true', 'false', 'test',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'fd',
    'diff', 'cmp', 'comm', 'uniq', 'cut', 'tr', 'column', 'nl', 'rev', 'tac',
    'fold', 'expand', 'paste', 'join', 'od', 'strings', 'seq',
    'jq', 'shasum', 'md5sum', 'sha256sum',
    'sort', 'find', 'sed', 'xxd', 'base64', 'git', 'awk',   # 인자를 따로 본다
}
# awk 는 system()·리다이렉트로 임의 쓰기가 되지만, `awk '{print $1}'` 은 너무 흔한
# 읽기 관용구라 통째로 막으면 과차단이 심하다. 프로그램이 한 토큰이므로 안을 본다.
AWK_WRITE = re.compile(r'''system\s*\(|close\s*\(|ENVIRON|>>|>\s*["'/]|\|''')
# 서브커맨드만으로 읽기가 확정되는 것 (branch/tag/reflog 는 생성·삭제가 되므로 제외)
GIT_READ = {
    'status', 'log', 'diff', 'show', 'rev-parse', 'rev-list', 'ls-files',
    'ls-tree', 'ls-remote', 'blame', 'describe', 'cat-file', 'shortlog',
    'whatchanged', 'grep', 'count-objects', 'var', 'symbolic-ref', 'name-rev',
    'merge-base', 'check-ignore', 'diff-tree',
}
# 첫 인자까지 봐야 읽기인지 갈리는 것
GIT_READ_SUB = {
    'remote': {'-v', 'show', 'get-url'},
    'stash': {'list', 'show'},
    'config': {'--get', '--get-all', '--get-regexp', '--list', '-l'},
    'worktree': {'list'},
    'submodule': {'status'},
    'notes': {'list', 'show'},
}
# 허용 명령이라도 이 인자가 붙으면 파일을 쓴다.
# 명령별로 좁혀야 한다 — `-o`는 sort에서 출력이지만 grep에서는 --only-matching,
# `-i`는 sed에서 제자리 수정이지만 base64/grep에서는 전혀 다른 뜻이다.
WRITE_FLAG_ANY = {'--output'}
WRITE_PREFIX_ANY = ('--output=',)
WRITE_FLAG_CMD = {
    'sort':   {'exact': {'-o'}, 'prefix': ('-o',)},
    'base64': {'exact': {'-o'}, 'prefix': ()},
    'sed':    {'exact': set(),  'prefix': ('-i',)},
    'find':   {'exact': {'-fls'}, 'prefix': ('-fprint',)},
}

NL = '\x00NL\x00'          # shlex가 개행을 공백으로 지우므로 구분자로 살려둔다
XXD_VALUE_FLAGS = {'-c', '-cols', '-g', '-groupsize', '-l', '-len',
                   '-o', '-s', '-seek'}
SEPARATORS = {';', '&&', '||', '|', '&', NL, ';;', '|&'}
# 안을 들여다볼 수 없는 구문 — 무엇을 하는지 판정 불가라 거부한다
OPAQUE = {'(', ')', '{', '}', '$', '`', '<(', '>(', '<<', '<<<'}
REDIR = re.compile(r'^[0-9]*(>{1,2}\|?|<|&>{1,2})$')
SED_W = re.compile(r'(^|[;/])w\s+\S')
ENGINE_PARTS = ('.ai-bouncer/tasks', 'workflow.compiled.json', '.claude/ai-bouncer')


def out(msg):
    sys.stdout.write(msg)
    sys.exit(0)


def tokenize(cmd):
    # 개행은 shlex 가 공백처럼 지운다. 구분자로 살리려면 센티널로 바꿔둔다.
    # 따옴표 안의 개행은 토큰 내부에 남으므로(단독 토큰이 아니므로) 구분자가 되지 않는다.
    lx = shlex.shlex(cmd.replace('\n', ' ' + NL + ' '), posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ''          # bash 는 단어 중간 # 을 주석으로 보지 않는다
    try:
        toks = list(lx)
    except ValueError:
        return None
    return [t if t == NL else t.replace(NL, '\n') for t in toks]


def norm(p):
    p = p.strip('"\'')
    if p.startswith(PROJECT + '/'):
        p = p[len(PROJECT) + 1:]
    return os.path.normpath(p).lstrip('./') or '.'


def glob_re(pat):
    i, o = 0, ['^']
    while i < len(pat):
        if pat.startswith('**/', i):
            o.append('(?:.*/)?'); i += 3
        elif pat.startswith('**', i):
            o.append('.*'); i += 2
        elif pat[i] == '*':
            o.append('[^/]*'); i += 1
        elif pat[i] == '?':
            o.append('[^/]'); i += 1
        else:
            o.append(re.escape(pat[i])); i += 1
    return re.compile(''.join(o) + '$')


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


def split_commands(tokens):
    cur, res = [], []
    for t in tokens:
        if t in SEPARATORS:
            if cur:
                res.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        res.append(cur)
    return res


def exe_of(cmd):
    # 환경변수 접두(X=1)를 건너뛰고 실제 실행 파일을 찾는다
    i = 0
    while i < len(cmd):
        t = cmd[i].strip('"\'').lstrip('\\')
        if '=' in t and '/' not in t and not t.startswith('-'):
            i += 1; continue
        return os.path.basename(t), cmd[i:]
    return '', []


def git_sub(cmd):
    i = 1
    while i < len(cmd):
        t = cmd[i]
        if t in ('-C', '--git-dir', '--work-tree', '--namespace', '--exec-path'):
            i += 2; continue
        if t == '-c':
            return None
        if t.startswith('-'):
            i += 1; continue
        return t
    return None


TOKENS = tokenize(CMD)
if TOKENS is None:
    out("따옴표가 닫히지 않아 명령을 판정할 수 없다.")

# ── 엔진 파일은 항상 보호 ──────────────────────────────────────
if any(part in CMD.replace('\\', '/') for part in ENGINE_PARTS) or \
   any(part in norm(t) for t in TOKENS for part in ENGINE_PARTS):
    e0, _ = exe_of(TOKENS) if TOKENS else ('', [])
    if e0 not in ('bouncer', 'bouncer.sh'):
        out("엔진 파일(state.json / .active / workflow.compiled.json / .claude/ai-bouncer/)은 "
            "직접 다룰 수 없다.")

if EDIT is not None:
    # ── 읽기 전용 스테이지 ────────────────────────────────────
    bad = (set(TOKENS) & OPAQUE) | {t for t in TOKENS if '`' in t or '$(' in t}
    if bad:
        out("이 단계는 읽기 전용이다. 안을 확인할 수 없는 구문(%s)은 쓸 수 없다.\n"
            "검증 명령을 돌려야 하면 `bouncer run <step-id>` 를 써라." % ' '.join(sorted(bad)))

    # 리다이렉트는 /dev/null 로만 (2>/dev/null 같은 관용구를 살린다)
    clean = []
    i = 0
    while i < len(TOKENS):
        t = TOKENS[i]
        if REDIR.match(t):
            tgt = TOKENS[i + 1].strip('"\'') if i + 1 < len(TOKENS) else ''
            if tgt != '/dev/null':
                out("이 단계는 읽기 전용이다. 파일로 출력을 보낼 수 없다: %s %s" % (t, tgt))
            i += 2; continue
        clean.append(t); i += 1

    for cmd in split_commands(clean):
        exe, cmd = exe_of(cmd)
        if not exe or exe in ('bouncer', 'bouncer.sh'):
            continue
        if exe not in READ_ONLY:
            out("이 단계는 읽기 전용이다. `%s` 는 파일을 쓸 수 있어 허용되지 않는다.\n"
                "읽기·검색은 가능하고, 검증 명령은 `bouncer run <step-id>` 로 실행한다." % exe)
        args = cmd[1:]
        spec = WRITE_FLAG_CMD.get(exe, {'exact': set(), 'prefix': ()})
        for a in args:
            if a in WRITE_FLAG_ANY or a.startswith(WRITE_PREFIX_ANY) \
               or a in spec['exact'] or (spec['prefix'] and a.startswith(spec['prefix'])):
                out("`%s %s` 는 파일을 쓴다. 이 단계에서는 허용되지 않는다." % (exe, a))
        if exe in ('awk', 'gawk', 'mawk', 'nawk'):
            if any(a in ('-f', '--file', '--source') or a.startswith('--file=')
                   for a in args):
                out("`awk -f <파일>` 은 프로그램을 확인할 수 없어 허용되지 않는다.")
            hit = [a for a in args if AWK_WRITE.search(a)]
            if hit:
                out("이 awk 프로그램은 파일을 쓰거나 명령을 실행할 수 있다: %s" % hit[0][:60])
        if exe == 'sed' and any(SED_W.search(a) for a in args):
            out("sed 스크립트의 `w` 플래그는 파일을 쓴다. 이 단계에서는 허용되지 않는다.")
        # xxd 는 두 번째 위치 인자를 출력 파일로 쓴다.
        # 값을 받는 플래그(-l 32 등)를 건너뛰어야 32 를 파일로 오인하지 않는다.
        if exe == 'xxd':
            pos, i2 = 0, 0
            while i2 < len(args):
                a = args[i2]
                if a in XXD_VALUE_FLAGS:
                    i2 += 2; continue
                if a.startswith('-'):
                    i2 += 1; continue
                pos += 1; i2 += 1
            if pos > 1:
                out("`xxd <입력> <출력>` 은 파일을 쓴다. 출력 인자를 빼라.")
        if exe == 'find' and any(a in ('-exec', '-execdir', '-delete', '-ok', '-okdir')
                                 for a in args):
            out("`find -exec/-delete` 는 임의 명령을 실행한다. 이 단계에서는 허용되지 않는다.")
        if exe == 'git':
            sub = git_sub(cmd)
            if sub is None:
                out("이 git 명령이 무엇을 하는지 판정할 수 없다 (`-c` 등).")
            if sub in GIT_READ_SUB:
                rest = [a for a in args if a != sub]
                if not (rest and rest[0] in GIT_READ_SUB[sub]):
                    out("`git %s` 는 이 형태로는 읽기가 아니다. 허용: %s"
                        % (sub, ', '.join(sorted(GIT_READ_SUB[sub]))))
            elif sub not in GIT_READ:
                out("`git %s` 는 읽기 명령이 아니다. 이 단계에서는 허용되지 않는다." % sub)
        if EDIT is not True:
            for a in args:
                if not a.startswith('-') and path_forbidden(a):
                    out("`%s` 로 %s 를 다룰 수 없다." % (exe, a))

elif PUSH:
    # ── push 만 금지된 스테이지 ───────────────────────────────
    # 구분자로 나눈 뒤 각 조각을 본다. 연산자를 지우고 첫 토큰만 보면
    # `true && git push` 가 통째로 한 명령이 되어 빠져나간다.
    for cmd in split_commands(TOKENS):
        exe, cmd = exe_of(cmd)
        if exe == 'git-push':
            out("push가 차단되었다.")
        if exe in ('awk', 'gawk', 'python', 'python3', 'perl', 'ruby', 'node', 'sh', 'bash') \
           and any('push' in a for a in cmd[1:]):
            out("인터프리터·셸을 통한 push 시도로 보인다. 이 단계에서는 허용되지 않는다.")
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
