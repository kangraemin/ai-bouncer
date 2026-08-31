#!/usr/bin/env python3
"""테스트용 — workflow.yaml의 settings 값을 덮어쓴다.
usage: set-settings.py <yaml> key=value [key=value ...]
"""
import re, sys

path, pairs = sys.argv[1], sys.argv[2:]
lines = open(path).read().split('\n')

# 기존 settings 블록 제거
out, i = [], 0
while i < len(lines):
    if re.match(r'^settings:\s*$', lines[i]):
        i += 1
        while i < len(lines) and (lines[i].startswith((' ', '\t')) or lines[i].strip() == ''):
            if lines[i].strip() == '' and i + 1 < len(lines) and not lines[i+1].startswith((' ', '\t')):
                break
            i += 1
        continue
    out.append(lines[i]); i += 1

block = ['settings:'] + ['  %s: %s' % tuple(p.split('=', 1)) for p in pairs]
for n, line in enumerate(out):
    if line.startswith('version:'):
        out[n+1:n+1] = [''] + block
        break
open(path, 'w').write('\n'.join(out))
