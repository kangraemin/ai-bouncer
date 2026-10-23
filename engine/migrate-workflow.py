#!/usr/bin/env python3
"""옛 형식 workflow.yaml 을 지금 형식(workflows / stages.<단계>.{prompt, run, items, choosable})으로 바꾼다.

install/update(bouncer init) 때마다 돈다. 이미 지금 형식이면 아무것도 바꾸지 않는다(멱등).
  - 단계의 run step 은 그 단계의 run 으로 옮긴다({scope} 자리는 지운다). 잠깐 썼던 checks 는 verify.run 으로.
  - 나머지(지시문, workflows, settings, forbid, on_fail, remove …)는 버리고 목록을 출력한다.
    옛 파일의 지시문·모드는 대부분 기본값 사본이었다. 기본값이 그 자리를 채운다.
  - 주석은 사라진다. 원본은 workflow.yaml.bak 로 남긴다.
usage: migrate-workflow.py <workflow.yaml>
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compile as C            # noqa: E402

HEADER = '''# ai-bouncer 레포 설정 — 기본값과 같은 형식. 모드·단계를 이름 단위로 교체하거나 추가한다.
#   stages.<단계>.prompt  할 일 / run  통과 조건(exit 0) / items  세부 항목
#   stages.<단계>.choosable  항목을 고르는 방식: ask 사용자에게 묻는다 / auto AI 가 고른다 / all 전부(기본)
# 형식: docs/SCHEMA.md
'''


# ── 최소 YAML 출력기 (pyyaml·내장 파서 양쪽에서 같은 값으로 읽히는 부분집합) ──────────
def _key(k):
    return k if re.match(r'^[A-Za-z_][\w.-]*$', k) else json.dumps(k, ensure_ascii=False)


def _block_ok(s):
    if '\n' not in s.rstrip('\n') or '\r' in s or '\t' in s or s.endswith('\n\n'):
        return False
    lines = s.rstrip('\n').split('\n')
    return not lines[0].startswith(' ') and not any(l != l.rstrip() for l in lines)


def _scalar(v, ind, block):
    if v is None:
        return 'null'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        if block and _block_ok(v):
            head = '|' if v.endswith('\n') else '|-'
            pad = ' ' * (ind + 2)
            body = '\n'.join((pad + l) if l else '' for l in v.rstrip('\n').split('\n'))
            return head + '\n' + body
        return json.dumps(v, ensure_ascii=False)
    raise TypeError(type(v))


def emit(obj, ind=0, block=True):
    pad = ' ' * ind
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, dict) and v:
                out.append('%s%s:\n%s' % (pad, _key(k), emit(v, ind + 2, block)))
            elif isinstance(v, list) and v and any(isinstance(x, dict) for x in v):
                out.append('%s%s:\n%s' % (pad, _key(k), emit(v, ind + 2, block)))
            elif isinstance(v, list):
                out.append('%s%s: [%s]' % (pad, _key(k), ', '.join(json.dumps(x, ensure_ascii=False) for x in v)))
            elif isinstance(v, dict):
                out.append('%s%s: {}' % (pad, _key(k)))
            else:
                out.append('%s%s: %s' % (pad, _key(k), _scalar(v, ind, block)))
    else:                                    # 리스트 (항목은 매핑)
        for x in obj:
            body = emit(x, ind + 2, block).split('\n')
            body[0] = pad + '- ' + body[0][ind + 2:]
            out.append('\n'.join(body))
    return '\n'.join(out)


# ── 변환 ─────────────────────────────────────────────────────
def is_legacy(raw):
    if set(raw) - C.ROOT_KEYS:
        return True
    stages = raw.get('stages')
    return isinstance(stages, dict) and any(
        isinstance(b, dict) and set(b) - C.STAGE_KEYS for b in stages.values())


def _cmd(c):
    return re.sub(r'\s*\{scope\}', '', c).strip() if isinstance(c, str) else ''


def convert(raw):
    """(지금 형식 dict, 버린 항목 설명 리스트)"""
    dropped = ['%s' % k for k in sorted(set(raw) - {'version', 'stages', 'checks'})]
    stages = {}
    for name, body in (raw.get('stages') or {}).items():
        if not isinstance(body, dict):
            continue
        runs = [_cmd(c) for c in ([body['run']] if isinstance(body.get('run'), str) else body.get('run') or [])]
        for st in body.get('steps') or []:
            if isinstance(st, dict) and _cmd(st.get('run')):
                runs.append(_cmd(st['run']))
            elif isinstance(st, dict):
                dropped.append('stages.%s/%s' % (name, st.get('label') or '(이름 없음)'))
        dropped += ['stages.%s.%s' % (name, k) for k in sorted(set(body) - {'run', 'steps'})]
        runs = [c for c in runs if c]
        if runs:
            stages[name] = {'run': runs}
    for c in raw.get('checks') or []:
        if isinstance(c, dict) and _cmd(c.get('run')):
            stages.setdefault('verify', {}).setdefault('run', []).append(_cmd(c['run']))
    return ({'stages': stages} if stages else {}), dropped


def main(argv):
    if len(argv) < 2:
        sys.stderr.write('usage: migrate-workflow.py <workflow.yaml>\n')
        return 2
    path = os.path.abspath(argv[1])
    if not os.path.isfile(path):
        return 0
    repo_dir = os.path.dirname(path)
    try:
        raw, _ = C.load_yaml(path)
        if not raw or not isinstance(raw, dict) or not is_legacy(raw):
            return 0                          # 이미 지금 형식
        ov, drop = convert(raw)

        text = None
        for block in (True, False):
            cand = HEADER + ('\n' + emit(ov, 0, block) + '\n' if ov else '')
            tmp = path + '.migrate.tmp'
            with open(tmp, 'w', encoding='utf-8') as fh:
                fh.write(cand)
            try:
                a, _ = C.load_yaml(tmp)
                b, _ = C.load_yaml(tmp, force_mini=True)
            finally:
                os.unlink(tmp)
            if (a or {}) == ov and (b or {}) == ov:
                text = cand
                break
        if text is None:
            sys.stderr.write('ai-bouncer: workflow.yaml 변환 결과가 원본과 달라 건너뛴다(그대로 둔다)\n')
            return 0
        # 변환 결과가 컴파일되는지 본다. 안 되면 원본을 건드리지 않는다.
        base_path = C.find_base(HERE)
        if base_path:
            base_raw, _ = C.load_yaml(base_path)
            C.compile_config(C.merge(base_raw, os.path.dirname(base_path), ov, repo_dir), [])
    except Exception as exc:                 # 마이그레이션 실패가 설치를 막으면 안 된다
        sys.stderr.write('ai-bouncer: workflow.yaml 변환 건너뜀 — %s\n' % exc)
        return 0

    bak = path + '.bak'
    if os.path.exists(bak):
        bak = '%s.bak-%s' % (path, time.strftime('%Y%m%d%H%M%S'))
    with open(path, encoding='utf-8') as fh:
        orig = fh.read()
    with open(bak, 'w', encoding='utf-8') as fh:
        fh.write(orig)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)
    print('  workflow.yaml: 지금 형식으로 변환 — run %d개 (원본 %s)' % (sum(len(b['run']) for b in ov.get('stages', {}).values()), os.path.basename(bak)))
    if drop:
        print('    옮기지 않은 것(필요하면 prompt 로 다시 적는다): %s' % ', '.join(drop))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
