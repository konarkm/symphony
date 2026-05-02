#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-4000}"
WORKFLOW="${1:-WORKFLOW.md}"

if ! command -v cloudflared >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared
  else
    echo "cloudflared is not installed and Homebrew was not found." >&2
    exit 1
  fi
fi

echo "Starting cloudflared tunnel to http://127.0.0.1:${PORT} ..."
cloudflared tunnel --url "http://127.0.0.1:${PORT}" 2>&1 | sed -u 's/^/[cloudflared] /' &
tunnel_pid=$!

cleanup() {
  kill "${tunnel_pid}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Start Symphony in another terminal with:"
echo "  mise exec -- mix build && mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port ${PORT} ${WORKFLOW}"
echo
echo "Use the printed cloudflared https URL with Linear's webhook settings and path /webhooks/linear-agent."

wait "${tunnel_pid}"
