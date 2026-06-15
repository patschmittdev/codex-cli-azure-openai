# Verification log

This file records the live test that confirmed the configuration in this
repo actually routes Codex CLI traffic to Azure OpenAI. Re-run the smoke
test yourself with `scripts/smoke-test.sh` or `scripts/smoke-test.ps1`.

## Test run, 2026-06-01

| Item                | Value                                                |
| ------------------- | ---------------------------------------------------- |
| Codex CLI version   | `0.135.0` (installed via `npm i -g @openai/codex`)   |
| OS                  | Windows                                              |
| Azure OpenAI region | `australiaeast`                                      |
| AOAI resource       | `<redacted>.openai.azure.com`                        |
| Deployment          | `gpt-4.1` (model version `2025-04-14`, GlobalStandard) |
| API version         | `2025-04-01-preview`                                 |
| Wire API            | `responses`                                          |
| Auth                | Microsoft Entra ID via `az account get-access-token` |
| Analytics ping      | Disabled (`[analytics] enabled = false`)             |

### Step 1: raw curl against Azure (isolates Codex from Azure)

```text
POST https://<redacted>.openai.azure.com/openai/responses?api-version=2025-04-01-preview
Authorization: Bearer <entra-token>
Body: {"model":"gpt-4.1","input":"Reply with only PONG."}

HTTP 200
output[0].content[0].text = "PONG"
```

### Step 2: Codex CLI through the same endpoint

```text
$ codex exec --skip-git-repo-check --sandbox read-only \
    "Reply with exactly the single word PONG and nothing else."

OpenAI Codex v0.135.0
--------
model: gpt-4.1
provider: azure
approval: never
sandbox: read-only
session id: <redacted>
--------
user
Reply with exactly the single word PONG and nothing else.
codex
PONG
tokens used: 13,826
```

> Note: Codex's per-turn token count includes its built-in system prompt
> and tool/context overhead, so even a one-word answer reports thousands
> of tokens. That is normal, not a billing surprise specific to Azure.

### Step 3: a second prompt to confirm repeatability

```text
$ codex exec --skip-git-repo-check --sandbox read-only \
    "In one short sentence, what year did the Apollo 11 mission land on the moon? Then on a new line print exactly: TEST_OK"

provider: azure
model: gpt-4.1
session id: <redacted>
codex
The Apollo 11 mission landed on the moon in 1969.
TEST_OK
tokens used: 13,856
```

## Observed warnings

One non-fatal startup error appeared in both runs:

```text
ERROR codex_models_manager::manager: failed to refresh available models:
... missing field `models` ...
```

Root cause: Codex parses `/openai/models` expecting a top-level `models`
field; Azure returns `data` instead. Inference is unaffected. The README's
"Known caveats" section documents this; no workaround is needed.

## What the test did NOT cover

- API-key auth path (covered by config sample only).
- Managed-identity auth path on Azure compute (covered by config sample only).
- The `[otel]` exporter path (configurable but collector-specific).
- Codex IDE extension and desktop app surfaces. Both share the same
  `~/.codex/config.toml`, so they inherit the same routing, but were not
  independently exercised here.
