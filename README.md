# ai-bouncer

Claude Code 개발 flow 강제 도구.

계획 승인 없이 코드 수정 시도 → 차단.

## Flow

```
요청 → 계획 수립 → 사용자 승인
  → 단계별 테스트 정의 → 개발 → 테스트 통과
  → 다음 단계 반복 → 전체 회귀 테스트 → 완료
```

## 설치

```bash
bash <(curl -sL https://raw.githubusercontent.com/kangraemin/ai-bouncer/main/install.sh)
```

## 업데이트

```bash
cd ~/.claude && git pull  # claude-config 업데이트 시 자동 반영
```

## 포함 파일

- `agents/lead.md` — 계획 수립 + 오케스트레이션
- `agents/dev.md` — 구현
- `agents/qa.md` — 테스트/검증
- `commands/dev.md` — `/dev` 스킬
- `hooks/plan-gate.sh` — PreToolUse 차단 훅
