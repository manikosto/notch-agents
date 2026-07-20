#!/bin/bash
# Codex notify hook: пробрасывает событие (JSON в $1) в Notch Agents.
curl -s --max-time 2 -X POST -H 'Content-Type: application/json' \
  --data-binary "${1:-{}}" http://127.0.0.1:48738/codex-notify >/dev/null 2>&1 || true
