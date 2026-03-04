#!/bin/bash
# resolve-task: 공유 라이브러리
# 소싱 후 TASK_NAME, DOCS_BASE, TASK_DIR, STATE_FILE 설정

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
REPO_NAME=$(basename "$REPO_ROOT" 2>/dev/null)
PERSISTENT_ACTIVE="$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs/.active"

TASK_NAME=""
DOCS_BASE=""

if [ -f "$PERSISTENT_ACTIVE" ] && [ -s "$PERSISTENT_ACTIVE" ]; then
  TASK_NAME=$(cat "$PERSISTENT_ACTIVE" 2>/dev/null | tr -d '[:space:]')
  DOCS_BASE="$HOME/.claude/ai-bouncer/sessions/${REPO_NAME}/docs"
fi

if [ -z "$TASK_NAME" ] && [ -f "docs/.active" ]; then
  TASK_NAME=$(cat "docs/.active" 2>/dev/null | tr -d '[:space:]')
  DOCS_BASE="docs"
fi

if [ -n "$TASK_NAME" ]; then
  TASK_DIR="${DOCS_BASE}/${TASK_NAME}"
  STATE_FILE="${TASK_DIR}/state.json"
else
  TASK_DIR=""
  STATE_FILE=""
fi
