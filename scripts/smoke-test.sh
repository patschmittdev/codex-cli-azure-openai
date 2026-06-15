#!/usr/bin/env bash
# Smoke test: one-shot `codex exec` that asserts the provider banner says
# `azure` and that the assistant returned a unique sentinel string.
# Exits 0 on success, non-zero on failure.
set -euo pipefail

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex not on PATH. Install with: npm i -g @openai/codex" >&2
  exit 2
fi

CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: no config at $CONFIG. Copy one from config/ first." >&2
  exit 2
fi

echo "Using config: $CONFIG"
echo "Codex version: $(codex --version)"
echo

# Run codex non-interactively in read-only sandbox so it cannot touch files.
# Use a unique sentinel that does NOT appear in the prompt itself, so a
# request failure cannot falsely satisfy the check by echoing the prompt.
SENTINEL="CODEX_AZURE_SMOKE_OK"
set +e
OUT=$(codex exec --skip-git-repo-check --sandbox read-only --color never \
  "Reply with exactly the token ${SENTINEL} on a line by itself and nothing else." 2>&1)
STATUS=$?
set -e

echo "$OUT" | tail -n 30
echo

if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: codex exited with status $STATUS" >&2
  exit 1
fi

if echo "$OUT" | grep -q "^provider: azure$"; then
  echo "OK: provider banner shows azure"
else
  echo "FAIL: provider banner does not show azure" >&2
  exit 1
fi

# Require the sentinel on a line by itself, in the assistant's reply.
# Strip CRs first so the check also works on Windows-line-ended pipes.
if echo "$OUT" | tr -d '\r' | grep -qx "$SENTINEL"; then
  echo "OK: assistant returned the sentinel"
  exit 0
else
  echo "FAIL: did not see sentinel '$SENTINEL' on its own line" >&2
  exit 1
fi
