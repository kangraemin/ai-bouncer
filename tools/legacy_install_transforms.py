"""옛 install.sh 가 설치본 workflow.yaml / prompts/plan.md 에 직접 가하던 텍스트 변환(PYM·PYP)의 고정 사본.

그 변환을 거친 옛 기본값 사본은 git 이력의 어느 default.yaml 과도 글자가 다르다.
gen-legacy-defaults.py 가 이 변환을 이력의 각 버전에 적용해 "옛 install 이 만들어 냈을 사본"도
옛 기본값 지문에 넣는다. install.sh 에서는 그 변환 코드를 지웠다(base+override 로 필요가 없어졌다).
"""
import re


def pym(s):
    return re.sub(r'(- label: 검증 보고\n(\s+)blocking: )true\b', r'\1done', s, count=1)


def _shift_after(s, start, ind, k):
    lines = s[start:].splitlines(True)
    for i, line in enumerate(lines):
        mm = re.match(re.escape(ind) + r'(\d+)\. ', line)
        if mm and int(mm.group(1)) == k:
            lines[i] = '%s%d. ' % (ind, k - 1) + line[mm.end():]
            k += 1
        elif mm or not line.startswith(ind + ' '):
            break
    return s[:start] + ''.join(lines)


def _drop_item(s, phrase):
    m = re.search(r'(?m)^( +)(\d+)\. ' + re.escape(phrase) + r'\n', s)
    if not m:
        return s
    return _shift_after(s[:m.start()] + s[m.end():], m.start(), m.group(1), int(m.group(2)) + 1)


def pyp_workflow(s):
    s = s.replace('승인된 계획의 After 코드를 그대로 구현한다. 범위를 임의로 넓히거나 줄이지 않는다.\n',
                  '승인된 계획의 After 코드를 그대로 구현한다.\n')
    s = s.replace('요청받은 범위만 구현한다. 계획을 세운 뒤라면 그 계획의 After 코드를 그대로 옮긴다.\n',
                  '계획을 세운 뒤라면 그 계획의 After 코드를 그대로 옮긴다.\n')
    s = re.sub(r'(?m)^ +범위를 임의로 넓히거나 줄이지 않는다\.\n', '', s)
    s = re.sub(r'한다\. 어느 파일 어디에 넣었는지\n( +)함께 보고해라\. ', r'한다.\n\1', s)
    s = _drop_item(s, '실행한 명령어와 출력을 사용자에게 보고한다.')
    m = re.search(r'(?m)^( +)(\d+)\. 커밋한다 — type은 영어, 설명은 한글, 50자 이내\.\n\1\d+\. push한다\.\n', s)
    if m:
        s = s[:m.start()] + '%s%s. 커밋하고 push한다.\n' % (m.group(1), m.group(2)) + s[m.end():]
        s = _shift_after(s, s.index('\n', m.start()) + 1, m.group(1), int(m.group(2)) + 2)
    s = s.replace('[done] 작업이 끝났다. 무엇을 바꿨는지 한 번 요약해 보고하고 멈춘다.\n          사용자 지시 없이',
                  '[done] 작업이 끝났다. 사용자 지시 없이')
    s = re.sub(r'(?m)^( +- label: 검증 보고\n)(?: +#[^\n]*\n)*? +blocking: (?:done|true)\n', r'\1', s)
    s = re.sub(r'(?ms)^( +)요청받은 항목을 \*\*할 일 목록으로 먼저 세운다\.\*\*.*?^\1체크는 \*\*실제로 그 코드를 넣은 뒤에\*\* 한다\.[^\n]*\n(?:\1\S[^\n]*\n)*',
               lambda m: m.group(1) + '할 일 목록이 있으면(plan 모드는 승인된 계획에서 옮겨진다) 엔진이 항목 수를 센다.\n'
                         + m.group(1) + '구현한 항목은 `bouncer todo done <번호>`, 뺄 항목은 `bouncer todo drop <번호>`(사유를 알린다).\n', s)
    return s


def pyp_plan(p):
    p = _drop_item(p, '관련 코드를 실제로 읽는다. 추측으로 계획을 쓰지 않는다.')
    p = _drop_item(p, '계획을 사용자에게 텍스트로 출력해 눈으로 볼 수 있게 한다.')
    return p
