#!/usr/bin/env python3
"""셸 명령이 이 스테이지에서 허용되는지 판정한다.

정규식 블랙리스트로는 못 막는다는 게 감사로 확인됐다 —
따옴표 한 쌍(`"rm" -f`), 인터프리터(`python3 -c "open(...,'w')"`),
에디터(`ed`/`ex`), git write 서브커맨드가 전부 빠져나갔다.
그래서 명령을 세그먼트로 쪼개고 각 세그먼트의 실행 파일 이름을 정규화해서 본다.

stdin: hook 입력 JSON에서 뽑은 명령 문자열
argv:  <edit_files_json> <push_bool> <bash_patterns_json> <project_dir>
출력:  차단 사유 (없으면 빈 출력)
"""
import fnmatch
import json
import re
import shlex
import sys

CMD, EDIT, PUSH, PATTERNS, PROJECT = (sys.stdin.read(),) + tuple(sys.argv[1:5])
EDIT = json.loads(EDIT)
PUSH = PUSH == "true"
PATTERNS = json.loads(PATTERNS)

# 작업 트리를 바꾸는 것으로 알려진 실행 파일.
# 인터프리터·에디터는 무엇이든 쓸 수 있으므로 여기 포함한다.
WRITERS = {
    'rm', 'mv', 'cp', 'touch', 'truncate', 'mkdir', 'rmdir', 'tee', 'dd',
    'install', 'ln', 'chmod', 'chown', 'patch', 'shred', 'rsync',
    'sed', 'awk', 'gawk', 'perl', 'python', 'python2', 'python3',
    'node', 'ruby', 'php', 'deno', 'bun',
    'ed', 'ex', 'vi', 'vim', 'nvim', 'emacs', 'nano', 'tee-a',
    'sponge', 'xargs', 'find',
}
# git 중 작업 트리나 원격을 바꾸는 서브커맨드
GIT_WRITE = {'checkout', 'restore', 'reset', 'clean', 'apply', 'stash',
             'rm', 'mv', 'switch', 'revert', 'cherry-pick', 'merge', 'rebase',
             'am', 'commit', 'add'}
# 셸을 다시 부르는 것들 — 안쪽을 못 보므로 그대로 위험 취급
SHELLS = {'sh', 'bash', 'zsh', 'ksh', 'dash', 'env', 'eval', 'exec', 'command', 'nohup', 'setsid'}

ENGINE_RE = re.compile(
    r'(\.ai-bouncer/tasks/[^\s\'"]*/(state\.json|\.active)'
    r'|workflow\.compiled\.json'
    r'|\.claude/ai-bouncer/)')


def segments(cmd):
    """; && || | 개행으로 쪼갠다. 따옴표 안의 구분자는 무시한다."""
    out, buf, quote, i = [], [], None, 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == quote:
                quote = None
        elif c in '"\'':
            quote = c
            buf.append(c)
        elif c == '\\' and i + 1 < len(cmd):
            buf.append(c); buf.append(cmd[i + 1]); i += 1
        elif c in ';\n&|':
            # `>|` 는 noclobber 무시 리다이렉트다. 여기서 자르면 쓰기가 안 보인다.
            if c == '|' and ''.join(buf).rstrip().endswith('>'):
                buf.append(c)
            else:
                out.append(''.join(buf)); buf = []
        else:
            buf.append(c)
        i += 1
    out.append(''.join(buf))
    return [s.strip() for s in out if s.strip()]


def tokens(seg):
    try:
        return shlex.split(seg)
    except ValueError:
        # 따옴표가 안 닫힌 명령은 판정할 수 없다 — 위험 취급한다.
        return None


def exe_name(tok):
    """`"rm"` `/bin/rm` `\\rm` 을 전부 rm 으로 정규화한다."""
    t = tok.strip('"\'').lstrip('\\')
    return t.rsplit('/', 1)[-1]


def is_bouncer(seg):
    t = tokens(seg)
    return bool(t) and exe_name(t[0]) in ('bouncer', 'bouncer.sh')


def git_subcommand(toks):
    """git 의 서브커맨드를 찾는다. -C <경로> / -c k=v 같은 값 인자를 건너뛴다."""
    i = 1
    while i < len(toks):
        t = toks[i]
        if t in ('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path'):
            i += 2; continue
        if t.startswith('-'):
            i += 1; continue
        return t
    return None


def path_forbidden(p):
    if EDIT is None:
        return False
    if EDIT is True:
        return True
    rel = p[len(PROJECT) + 1:] if p.startswith(PROJECT + '/') else p
    rel = rel[2:] if rel.startswith('./') else rel
    hit = False
    for pat in EDIT:
        neg = pat.startswith('!')
        pat_ = pat[1:] if neg else pat
        if fnmatch.fnmatch(rel, pat_) or fnmatch.fnmatch(p, pat_):
            hit = not neg
    return hit


def deny(msg):
    sys.stdout.write(msg)
    sys.exit(0)


for seg in segments(CMD):
    toks = tokens(seg)

    # 엔진 파일은 스테이지와 무관하게 항상 보호한다.
    if ENGINE_RE.search(seg) and not is_bouncer(seg):
        deny("엔진 파일(state.json / .active / workflow.compiled.json / .claude/ai-bouncer/)은 "
             "직접 다룰 수 없다: %s" % seg[:80])

    # bouncer 명령은 게이트를 통과할 유일한 수단이므로 허용하되,
    # 그 세그먼트가 정확히 bouncer 호출일 때만이다. 뒤에 다른 명령을 붙이면
    # 각 세그먼트가 따로 판정되므로 무임승차가 안 된다.
    if is_bouncer(seg):
        continue

    if toks is None:
        deny("따옴표가 닫히지 않아 명령을 판정할 수 없다: %s" % seg[:80])

    exe = exe_name(toks[0]) if toks else ''

    if PUSH and exe in ('git', 'git-push'):
        if exe == 'git-push' or git_subcommand(toks) == 'push':
            deny("push가 차단되었다.")

    if EDIT is not None:
        # 리다이렉트는 어떤 형태든 쓰기다: > >> >| 그리고 세그먼트 첫 글자로 오는 경우
        if re.search(r'(^|[^0-9<>])>{1,2}\|?\s*\S', seg):
            targets = re.findall(r'>{1,2}\|?\s*([^\s;|&]+)', seg)
            for t in targets:
                if path_forbidden(t.strip('"\'')):
                    deny("셸 리다이렉트로 파일을 쓸 수 없다: %s" % t)
            if EDIT is True:
                deny("셸 리다이렉트로 파일을 쓸 수 없다: %s" % seg[:80])

        if exe in SHELLS:
            deny("이 단계에서는 다른 셸을 통해 명령을 실행할 수 없다 "
                 "(무엇을 하는지 확인할 수 없다): %s" % seg[:80])

        if exe == 'git':
            if git_subcommand(toks) in GIT_WRITE:
                deny("git %s 는 작업 트리를 바꾼다: %s" % (git_subcommand(toks), seg[:80]))
        elif exe in WRITERS:
            if EDIT is True:
                deny("`%s` 는 파일을 쓸 수 있다. 이 단계에서는 허용되지 않는다: %s" % (exe, seg[:80]))
            for t in toks[1:]:
                if not t.startswith('-') and path_forbidden(t):
                    deny("`%s` 로 %s 를 바꿀 수 없다." % (exe, t))

    for pat in PATTERNS:
        try:
            if re.search(pat, seg):
                deny("차단된 명령이다: %s" % seg[:80])
        except re.error:
            pass
