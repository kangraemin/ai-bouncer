#!/usr/bin/env python3
"""config/default.yaml · config/prompts/*.md 의 git 이력 전체를 config/legacy-defaults.json 으로 뽑는다.

기본값을 고칠 때마다(커밋한 뒤) 다시 돌려 커밋한다. 설치 때 migrate-workflow.py 가 이 파일로
"옛 기본값 그대로인 부분"을 알아본다. tests/cases/34 가 이력과 어긋나면 실패한다.
usage: python3 tools/gen-legacy-defaults.py
"""
import json
import os
import subprocess
import sys
import tempfile

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(R, 'engine'))
import compile as C            # noqa: E402
import legacy as L             # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legacy_install_transforms as T   # noqa: E402


def git(*a):
    return subprocess.run(['git', '-C', R] + list(a), capture_output=True, text=True, check=True).stdout


def history(path):
    out = []
    for h in git('log', '--format=%H', '--', path).split():
        try:
            out.append(git('show', '%s:%s' % (h, path)))
        except subprocess.CalledProcessError:
            pass
    return out


def build():
    versions, seen = [], set()
    variants = []
    for text in history('config/default.yaml'):
        # 옛 install.sh 가 사본에 가하던 변환을 거친 모양도 옛 기본값이다
        variants += [text, T.pym(text), T.pyp_workflow(T.pym(text)), T.pyp_workflow(text)]
    for text in variants:
        with tempfile.NamedTemporaryFile('w', suffix='.yaml', delete=False, encoding='utf-8') as fh:
            fh.write(text)
        try:
            raw, _ = C.load_yaml(fh.name)
        finally:
            os.unlink(fh.name)
        snap = L.snapshot(raw or {})
        key = json.dumps(snap, sort_keys=True, ensure_ascii=False)
        if key not in seen:
            seen.add(key)
            versions.append(snap)
    prompts = {}
    for name in sorted(os.listdir(os.path.join(R, 'config', 'prompts'))):
        rel = 'config/prompts/' + name
        prompts['prompts/' + name] = sorted({L.sha(v) for t in history(rel) for v in (t, T.pyp_plan(t))})
    return {'versions': versions, 'prompts': prompts}


if __name__ == '__main__':
    body = build()
    with open(os.path.join(R, 'config', 'legacy-defaults.json'), 'w', encoding='utf-8') as fh:
        json.dump(body, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write('\n')
    print('versions=%d prompts=%s' % (len(body['versions']), {k: len(v) for k, v in body['prompts'].items()}))
