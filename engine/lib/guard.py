#!/usr/bin/env python3
# 셸 명령이 이 스테이지에서 허용되는지 판정한다.
#
# 네 차례 감사에서 배운 것:
#  · 블랙리스트(쓰는 명령 열거)는 원리상 완결되지 않는다.
#  · 허용 목록만으로도 부족하다 — 목록 안의 명령에도 쓰기 모드가 있다
#    (`sed 1w out`, `sort -o`, `uniq in out`, `git symbolic-ref HEAD ref`).
#  · 판정 단위는 반드시 **세그먼트**여야 한다. 줄 전체의 첫 토큰만 보면
#    `bouncer status && rm -rf x` 가 통째로 통과한다.
#  · 래퍼(`env`, `nohup`, `xargs`…)와 환경변수 접두는 실행 파일 이름을 바꾼다.
#  · 문자열이 아니라 변수로 넘긴 경로는 들여다볼 수 없다 → 그런 형태는 거부한다.
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
EDIT = json.loads(sys.argv[1])          # true / 글로브 배열 / null
PUSH = sys.argv[2] == "true"
PATTERNS = json.loads(sys.argv[3])
PROJECT = sys.argv[4]

# 파일을 쓰지 않는 것으로 확인된 명령만.
# python/node/ruby/perl 은 임의 코드를 실행하므로 없다. awk 는 프로그램을 따로 본다.
READ_ONLY = {
    'ls', 'cat', 'head', 'tail', 'wc', 'file', 'stat', 'pwd', 'echo', 'printf',
    'basename', 'dirname', 'realpath', 'readlink', 'du', 'df', 'tree', 'which',
    'type', 'date', 'whoami', 'uname', 'hostname', 'id', 'true', 'false',
    'test', '[', 'command', 'env', 'printenv', 'ps', 'sw_vers', 'locale',
    'cd', 'pushd', 'popd', 'dirs',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'fd',
    'diff', 'cmp', 'comm', 'cut', 'tr', 'column', 'nl', 'rev', 'tac',
    'fold', 'expand', 'paste', 'join', 'od', 'strings', 'seq',
    'jq', 'shasum', 'md5sum', 'sha256sum',
    'sort', 'find', 'sed', 'xxd', 'base64', 'uniq', 'git', 'awk',  # 인자를 따로 본다
}
# 실행 파일 이름을 가리는 래퍼. 벗겨내고 진짜 명령을 봐야 한다.
WRAPPERS = {'env', 'command', 'nohup', 'time', 'stdbuf', 'timeout', 'nice',
            'ionice', 'setsid', 'caffeinate', 'xargs'}

# ── git ──────────────────────────────────────────────────────
# 어떤 인자를 줘도 읽기인 서브커맨드
GIT_READ = {
    'status', 'log', 'diff', 'show', 'rev-parse', 'rev-list', 'ls-files',
    'ls-tree', 'ls-remote', 'blame', 'describe', 'cat-file', 'shortlog',
    'whatchanged', 'grep', 'count-objects', 'var', 'name-rev', 'merge-base',
    'check-ignore', 'diff-tree', 'for-each-ref', 'show-branch', 'show-ref',
    'verify-pack', 'cherry',
}
# 인자에 따라 읽기/쓰기가 갈리는 서브커맨드.
#   first    : 첫 위치인자가 이 집합에 있어야 읽기 (None이면 위치인자 개수로만 판정)
#   bare_ok  : 위치인자 없이 쓰면 읽기인가
#   max_pos  : 허용되는 위치인자 개수 상한
#   bad      : 하나라도 있으면 쓰기로 보는 플래그
GIT_SUB = {
    'remote':       dict(first={'show', 'get-url'}, bare_ok=True,  max_pos=1, bad=set()),
    'stash':        dict(first={'list', 'show'},    bare_ok=False, max_pos=2, bad=set()),
    'worktree':     dict(first={'list'},            bare_ok=False, max_pos=1, bad=set()),
    'submodule':    dict(first={'status'},          bare_ok=True,  max_pos=1, bad=set()),
    'notes':        dict(first={'list', 'show'},    bare_ok=True,  max_pos=2, bad=set()),
    'reflog':       dict(first={'show'},            bare_ok=True,  max_pos=2, bad=set()),
    # 목록 형태만 읽기다. `git branch <이름>` 은 브랜치를 만든다.
    'branch':       dict(first=None, bare_ok=True, max_pos=0,
                         bad={'-d', '-D', '--delete', '-m', '-M', '--move', '-c', '-C',
                              '--copy', '-f', '--force', '-u', '--set-upstream-to',
                              '--unset-upstream', '--edit-description'}),
    'tag':          dict(first=None, bare_ok=True, max_pos=0,
                         bad={'-d', '--delete', '-a', '-s', '-m', '-f', '--force'}),
    # 인자 하나면 읽기, 둘이면 .git/HEAD 를 다시 쓴다.
    'symbolic-ref': dict(first=None, bare_ok=True, max_pos=1, bad={'-d', '--delete'}),
    'config':       dict(first=None, bare_ok=True, max_pos=1,
                         bad={'--add', '--unset', '--unset-all', '--replace-all',
                              '--rename-section', '--remove-section', '-e', '--edit'}),
}
GIT_PUSH_SUBS = {'push', 'send-pack', 'svn', 'p4', 'request-pull'}

# ── 쓰기 인자 ────────────────────────────────────────────────
# 명령별로 좁혀야 한다 — `-o`는 sort에서 출력이지만 grep에서는 --only-matching,
# `-i`는 sed에서 제자리 수정이지만 base64/grep에서는 전혀 다른 뜻이다.
WRITE_FLAG_ANY = {'--output'}
WRITE_PREFIX_ANY = ('--output=',)
WRITE_FLAG_CMD = {
    'sort':   {'exact': {'-o'},   'prefix': ('-o',)},
    'base64': {'exact': {'-o'},   'prefix': ()},
    'sed':    {'exact': set(),    'prefix': ('-i', '--in-place')},
    'find':   {'exact': {'-fls'}, 'prefix': ('-fprint',)},
}
# 두 번째 위치인자를 출력 파일로 쓰는 명령 → 값을 받는 플래그를 건너뛰고 세야 한다
POSITIONAL_OUT = {
    'xxd':  {'-c', '-cols', '-g', '-groupsize', '-l', '-len', '-o', '-s', '-seek'},
    'uniq': {'-f', '-s', '-w', '--skip-fields', '--skip-chars', '--check-chars'},
}
# sed 의 w/W 명령. 주소가 앞에 붙으면(`1w`, `$w`, `1,$w`) 놓치기 쉬워 문자군을 넓게 잡는다.
SED_W = re.compile(r'(^|[;/}0-9$,~+])[wW]\s+\S')
SED_W_SPLIT = re.compile(r'^[0-9$,~+/]*[wW]$')
# awk 프로그램 안의 쓰기·실행. 변수를 거친 리다이렉트까지 잡으려면
# 대상 형태가 아니라 `print`/`printf` 뒤의 `>` 자체를 봐야 한다.
AWK_EXEC = re.compile(r'system\s*\(|close\s*\(|ENVIRON|\|')
AWK_STMT_SPLIT = re.compile(r'[;{}\n]')

# ── 환경변수 접두 ────────────────────────────────────────────
ENV_SAFE = {'LANG', 'TZ', 'TERM', 'NO_COLOR', 'CLICOLOR', 'COLUMNS', 'LINES'}
# 값이 그대로 실행되거나 로딩되는 것들. GIT_* 는 통째로 막는다
# (GIT_EXTERNAL_DIFF, GIT_SSH, GIT_CONFIG_KEY_n 으로 별칭 주입이 전부 가능하다).
ENV_DANGEROUS_PREFIX = ('GIT_', 'LD_', 'DYLD_', 'BASH_', 'PERL5', 'PYTHON', 'NODE_')
ENV_DANGEROUS = {'PATH', 'ENV', 'IFS', 'SHELL', 'EDITOR', 'VISUAL', 'PAGER'}

# 안을 들여다볼 수 없는 구문 — 무엇을 하는지 판정 불가라 거부한다
OPAQUE = {'(', ')', '{', '}', '$', '`', '<(', '>('}
SEPARATOR_BASE = {';', '&&', '||', '|', '&', ';;', '|&'}
NL = '\x00NL\x00'          # shlex가 개행을 공백으로 지우므로 구분자로 살려둔다
SEPARATORS = SEPARATOR_BASE | {NL}
# 리다이렉트 연산자. 앞에 붙는 fd 번호는 별도 토큰으로 떨어지므로 여기 없다.
REDIR = re.compile(r'^(>{1,2}\|?|<|<>|&>{1,2}|>&)$')
# 엔진 소유 경로. 부분문자열이 아니라 **경로 성분**으로 본다 —
# `.ai-bouncer/tasks` 만 보면 부모인 `rm -rf .ai-bouncer` 를 놓쳐 게이트가 통째로 사라진다.
ENGINE_DIRS = (('.ai-bouncer',), ('.claude', 'ai-bouncer'))
# 병렬 작업용 worktree는 ~/.ai-bouncer/worktrees/ 에 산다. 거기 있는 소스 파일은
# 엔진 상태가 아니라 **작업 대상**이라 막으면 안 된다.
ENGINE_EXEMPT = (('.ai-bouncer', 'worktrees'),)
ENGINE_FILES = ('workflow.compiled.json',)
BOUNCER_EXE = ('bouncer', 'bouncer.sh')
# 엔진 파일을 **읽기만** 하는 것은 막을 이유가 없다.
# (설정을 확인하려는 것뿐인데 스테이지마다 다르게 막히면 혼란만 준다)
ENGINE_READ_OK = {
    'cat', 'head', 'tail', 'wc', 'ls', 'stat', 'file', 'tree', 'du', 'jq',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'diff', 'cmp', 'nl', 'od',
    'strings', 'md5sum', 'sha256sum', 'shasum', 'realpath', 'dirname', 'basename',
}


ENGINE_MSG = ("엔진 파일(.ai-bouncer/ 상태, .claude/ai-bouncer/ 설정·엔진, "
              "workflow.compiled.json)은 직접 수정할 수 없다.\n"
              "읽는 것은 자유다 — `cat`/`ls`/`grep` 으로 확인해라.\n"
              "작업 상태를 바꾸려면 `bouncer` 명령을 써라.")


def out(msg):
    sys.stdout.write(msg)
    sys.exit(0)


def tokenize(cmd):
    # 개행은 shlex가 공백처럼 지운다. 구분자로 살리려면 센티널로 바꿔둔다.
    # 따옴표 안의 개행은 토큰 내부에 남으므로(단독 토큰이 아니므로) 구분자가 되지 않는다.
    lx = shlex.shlex(cmd.replace('\n', ' ' + NL + ' '), posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ''          # bash는 단어 중간 # 을 주석으로 보지 않는다
    try:
        toks = list(lx)
    except ValueError:
        return None
    return [t if t == NL else t.replace(NL, '\n') for t in toks]


def norm(p):
    """경로를 프로젝트 기준 상대경로로 정규화한다.

    normpath 가 `//` 와 `/./` 를 접는다. 예전에는 뒤에 `.lstrip('./')` 를 붙였는데,
    그건 문자군 제거라 `.claude` 의 선행 점까지 지워 엔진 파일 검사를 통째로
    무력화했고 `../secret` 을 `secret` 으로 바꿔놓기도 했다.
    """
    p = p.strip('"\'')
    if p.startswith(PROJECT + '/'):
        p = p[len(PROJECT) + 1:]
    return os.path.normpath(p) if p else '.'


def split_segments(tokens):
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


def parse_redirects(seg):
    """세그먼트를 (명령 토큰, [(연산자, 대상)]) 로 가른다.

    `2>/dev/null` 은 ['2', '>', '/dev/null'] 로 떨어지므로,
    연산자 앞의 숫자 토큰은 fd 번호로 보고 걷어낸다.
    """
    clean, redirs, i = [], [], 0
    while i < len(seg):
        t = seg[i]
        if REDIR.match(t):
            if clean and clean[-1].isdigit():
                clean.pop()
            tgt = seg[i + 1] if i + 1 < len(seg) else ''
            redirs.append((t, tgt.strip('"\'')))
            i += 2
            continue
        clean.append(t)
        i += 1
    return clean, redirs


def resolve_exe(seg):
    """(실행 파일 이름, 그 지점부터의 토큰, 환경변수 이름들) 을 돌려준다.

    `X=1 env nohup git push` 처럼 접두가 겹겹이 붙어도 진짜 명령까지 벗겨낸다.
    """
    env, i, last = [], 0, ''
    while i < len(seg):
        t = seg[i].strip('"\'').lstrip('\\')
        if '=' in t and '/' not in t and not t.startswith('-'):
            env.append(t.split('=', 1)[0])
            i += 1
            continue
        base = os.path.basename(t)
        last = base
        # `command -v foo` / `type -p foo` 는 조회다. 래퍼로 벗기면 foo가 명령이 된다.
        if base in ('command', 'type') and any(a in ('-v', '-V', '-p')
                                               for a in seg[i + 1:]):
            return base, seg[i:], env
        if base in WRAPPERS:
            j = i + 1
            while j < len(seg) and seg[j].startswith('-'):
                j += 1
            if j >= len(seg):           # 래퍼만 있고 뒤에 명령이 없다
                return base, seg[i:], env
            i = j
            continue
        return base, seg[i:], env
    return last, seg[i:] if i < len(seg) else [], env


def git_sub(cmd):
    """git 의 전역 옵션을 건너뛰고 서브커맨드를 찾는다. `-c` 는 판정 불가."""
    i = 1
    while i < len(cmd):
        t = cmd[i]
        if t in ('-C', '--git-dir', '--work-tree', '--namespace', '--exec-path'):
            i += 2
            continue
        if t == '-c':
            return None
        if t.startswith('-'):
            i += 1
            continue
        return t
    return ''


def awk_writes(prog):
    """awk 프로그램이 파일을 쓰거나 명령을 실행하는가.

    `$3 > 500` 같은 비교와 `print $1 > f` 를 갈라야 한다. 리다이렉트는 항상
    출력 목록 뒤에 오므로, `>` 앞쪽 같은 문장 안에 print/printf 가 있으면 쓰기로 본다.
    대상이 변수여도 잡힌다 — 대상 모양을 보지 않기 때문이다.
    """
    if AWK_EXEC.search(prog):
        return True
    if '>>' in prog:
        return True
    for m in re.finditer(r'>', prog):
        s, e = m.start(), m.end()
        if prog[s - 1:s] == '>' or prog[e:e + 1] in ('=', '>'):
            continue                    # >= 나 >> 의 일부
        head = AWK_STMT_SPLIT.split(prog[:s])[-1]
        if re.search(r'\bprintf?\b', head):
            return True
    return False


def is_engine_path(tok):
    """이 토큰이 엔진 소유 경로를 가리키는가. 성분 단위로 본다."""
    parts = norm(tok).replace('\\', '/').split('/')
    if parts[-1] in ENGINE_FILES:
        return True
    for want in ENGINE_EXEMPT:
        n = len(want)
        for i in range(len(parts) - n + 1):
            if tuple(parts[i:i + n]) == want:
                return False
    for want in ENGINE_DIRS:
        n = len(want)
        for i in range(len(parts) - n + 1):
            if tuple(parts[i:i + n]) == want:
                return True
    return False


def check_engine_files(segments):
    """엔진 파일은 어느 스테이지에서도 직접 **수정**할 수 없다.

    세그먼트마다 따로 본다. 줄 전체의 첫 토큰이 bouncer 인지로 면제하면
    `bouncer status && echo x > state.json` 이 통째로 빠져나간다.
    """
    for seg in segments:
        exe, cmd, _ = resolve_exe(seg)
        if exe in BOUNCER_EXE:
            continue
        clean, redirs = parse_redirects(seg)
        for op, tgt in redirs:
            if op != '<' and is_engine_path(tgt):
                out(ENGINE_MSG)
        if exe in ENGINE_READ_OK:
            continue                    # 읽기는 자유
        if any(is_engine_path(t) for t in clean):
            out(ENGINE_MSG)


def check_redirects(redirs):
    for op, tgt in redirs:
        if op == '<':
            continue                    # 입력 리다이렉트는 아무것도 쓰지 않는다
        if op == '>&' and tgt.isdigit():
            continue                    # 2>&1 같은 fd 복제
        if tgt != '/dev/null':
            out("이 단계는 읽기 전용이다. 파일로 출력을 보낼 수 없다: %s %s" % (op, tgt))


def check_env(env, readonly):
    for name in env:
        if readonly:
            if name in ENV_SAFE or name.startswith('LC_'):
                continue
            out("이 단계는 읽기 전용이다. 환경변수 접두(`%s=…`)는 무엇을 실행할지 "
                "판정할 수 없어 허용되지 않는다." % name)
        if name in ENV_DANGEROUS or name.startswith(ENV_DANGEROUS_PREFIX):
            out("`%s=…` 는 실행할 명령 자체를 바꿀 수 있어 이 단계에서는 허용되지 않는다."
                % name)


def check_git_read(cmd):
    sub = git_sub(cmd)
    if sub is None:
        out("`git -c …` 는 무엇을 하는지 판정할 수 없다(별칭 주입 가능). 허용되지 않는다.")
    if sub == '':
        return                          # `git` 만 치면 도움말
    if sub in GIT_READ:
        return
    if sub not in GIT_SUB:
        out("`git %s` 는 읽기 명령이 아니다. 이 단계에서는 허용되지 않는다." % sub)
    rule = GIT_SUB[sub]
    after = cmd[cmd.index(sub) + 1:]
    pos = [a for a in after if not a.startswith('-')]
    flags = [a for a in after if a.startswith('-')]
    for f in flags:
        head = f.split('=', 1)[0]
        if head in rule['bad']:
            out("`git %s %s` 는 쓰기 동작이다. 이 단계에서는 허용되지 않는다." % (sub, f))
    if not pos:
        if rule['bare_ok']:
            return
        out("`git %s` 는 이 형태로는 읽기가 아니다. 허용: %s"
            % (sub, ', '.join(sorted(rule['first']))))
    if rule['first'] is not None and pos[0] not in rule['first']:
        out("`git %s %s` 는 읽기가 아니다. 허용: %s"
            % (sub, pos[0], ', '.join(sorted(rule['first']))))
    if len(pos) > rule['max_pos']:
        out("`git %s` 에 인자를 %d개 주면 쓰기 동작이다 (읽기는 최대 %d개)."
            % (sub, len(pos), rule['max_pos']))


def check_readonly_cmd(exe, cmd):
    if exe in BOUNCER_EXE:
        return
    if exe not in READ_ONLY:
        out("이 단계는 읽기 전용이다. `%s` 는 파일을 쓸 수 있어 허용되지 않는다.\n"
            "읽기·검색은 가능하고, 검증 명령은 `bouncer run <step-id>` 로 실행한다." % exe)
    args = cmd[1:]
    spec = WRITE_FLAG_CMD.get(exe, {'exact': set(), 'prefix': ()})
    for a in args:
        if a in WRITE_FLAG_ANY or a.startswith(WRITE_PREFIX_ANY) \
           or a in spec['exact'] or (spec['prefix'] and a.startswith(spec['prefix'])):
            out("`%s %s` 는 파일을 쓴다. 이 단계에서는 허용되지 않는다." % (exe, a))
    if exe in POSITIONAL_OUT:
        value_flags, pos, i = POSITIONAL_OUT[exe], 0, 0
        while i < len(args):
            a = args[i]
            if a in value_flags:
                i += 2
                continue
            if a.startswith('-'):
                i += 1
                continue
            pos += 1
            i += 1
        if pos > 1:
            out("`%s <입력> <출력>` 은 두 번째 인자를 파일로 쓴다. 출력 인자를 빼라." % exe)
    if exe == 'sed':
        # 따옴표로 묶인 스크립트(`'1w out'`)와 공백으로 갈라진 형태(`1w out`) 둘 다 본다.
        if any(SED_W.search(a) for a in args) \
           or any(SED_W_SPLIT.match(a) for a in args[:-1]):
            out("sed 스크립트의 `w` 명령은 파일을 쓴다. 이 단계에서는 허용되지 않는다.")
    if exe == 'awk':
        if any(a in ('-f', '--file', '--source') or a.startswith('--file=') for a in args):
            out("`awk -f <파일>` 은 프로그램을 확인할 수 없어 허용되지 않는다.")
        for a in args:
            if not a.startswith('-') and awk_writes(a):
                out("이 awk 프로그램은 파일을 쓰거나 명령을 실행할 수 있다: %s" % a[:60])
    if exe == 'find' and any(a in ('-exec', '-execdir', '-delete', '-ok', '-okdir')
                             for a in args):
        out("`find -exec/-delete` 는 임의 명령을 실행한다. 이 단계에서는 허용되지 않는다.")
    if exe == 'git':
        check_git_read(cmd)


def check_push_cmd(exe, cmd):
    if exe == 'git-push':
        out("push가 차단되었다.")
    if exe in ('awk', 'gawk', 'python', 'python3', 'perl', 'ruby', 'node', 'sh', 'bash') \
       and any('push' in a for a in cmd[1:]):
        out("인터프리터·셸을 통한 push 시도로 보인다. 이 단계에서는 허용되지 않는다.")
    if exe != 'git':
        return
    sub = git_sub(cmd)
    if sub is None:
        out("`git -c …` 는 별칭으로 push를 숨길 수 있어 이 단계에서는 허용되지 않는다.")
    if sub in GIT_PUSH_SUBS:
        out("push가 차단되었다.")
    if sub == 'subtree' and 'push' in cmd:
        out("push가 차단되었다.")
    if sub == 'config' and any('alias.' in a for a in cmd):
        out("이 단계에서 git 별칭을 등록할 수 없다 (push를 숨길 수 있다).")


TOKENS = tokenize(CMD)
if TOKENS is None:
    out("따옴표가 닫히지 않아 명령을 판정할 수 없다.")

SEGMENTS = split_segments(TOKENS)
check_engine_files(SEGMENTS)

if EDIT is not None:
    # ── 읽기 전용 스테이지 ────────────────────────────────────
    # edit_files 가 글로브 배열이어도 셸에 대해서는 전면 읽기 전용으로 다룬다.
    # 셸 문법만으로 "무엇을 쓰는지" 를 확정할 수 없기 때문이다.
    # 허용된 경로에 쓰는 것은 Edit/Write 도구로 하면 되고, 그건 스코프대로 통과한다.
    bad = (set(TOKENS) & OPAQUE) | {t for t in TOKENS if '`' in t or '$(' in t}
    if bad:
        out("이 단계는 읽기 전용이다. 안을 확인할 수 없는 구문(%s)은 쓸 수 없다.\n"
            "검증 명령을 돌려야 하면 `bouncer run <step-id>` 를 써라." % ' '.join(sorted(bad)))
    for seg in SEGMENTS:
        clean, redirs = parse_redirects(seg)
        check_redirects(redirs)
        if not clean:
            continue
        exe, cmd, env = resolve_exe(clean)
        check_env(env, True)
        if exe:
            check_readonly_cmd(exe, cmd)

elif PUSH:
    # ── push 만 금지된 스테이지 ───────────────────────────────
    for seg in SEGMENTS:
        clean, _ = parse_redirects(seg)
        if not clean:
            continue
        exe, cmd, env = resolve_exe(clean)
        check_env(env, False)
        check_push_cmd(exe, cmd)

for pat in PATTERNS:
    try:
        if re.search(pat, CMD):
            out("차단된 명령이다: %s" % CMD[:80])
    except re.error:
        pass
