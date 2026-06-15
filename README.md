# Codex CLI with Azure OpenAI

A drop-in configuration guide for routing OpenAI Codex CLI (and the Codex IDE
extension and desktop app) at an **Azure OpenAI** deployment instead of
`api.openai.com`. Covers requests, auth, and telemetry.

> **Status:** verified end-to-end on 2026-06-01 against
> `Codex CLI 0.135.0` + Azure OpenAI `gpt-4.1` in `australiaeast` using
> Microsoft Entra ID. See [VERIFICATION.md](VERIFICATION.md).

---

## What this configures

All three "local" Codex surfaces share the same configuration file
(`~/.codex/config.toml`), so one config wires all of them:

| Surface                                | Routable to Azure? |
| -------------------------------------- | ------------------ |
| Codex CLI (`codex`)                    | Yes                |
| Codex IDE extension (VS Code / Cursor / Windsurf) | Yes     |
| Codex desktop app (`codex app`)        | Yes                |
| Codex Web (chatgpt.com/codex)          | **No**, cloud agent runs on OpenAI infra |

If your use case is the Web agent, this guide does not apply.

---

## Prerequisites

1. **Azure OpenAI resource** in a region that supports the Responses API.
   Codex CLI requires the Responses API (`wire_api = "responses"`); Chat
   Completions is not supported by current Codex. See the current region list
   in the
   [Azure Responses API docs](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/responses#supported-regions).
2. **A deployed model** that supports the Responses API. Known-good families:
   `gpt-5`, `gpt-5-codex`, `gpt-5.1`, `gpt-5.2`, `gpt-4.1`, `o3`, `o4-mini`,
   and `gpt-4o`. Match the deployment name to the value of `model` in your
   `config.toml`. **Recommended for coding work:** the `gpt-5-codex` family,
   which Codex CLI is tuned for. `gpt-4.1` works as a fallback but produces
   noticeably weaker agent behavior on multi-step tasks.
3. **Authentication.** Pick one:
   - **Microsoft Entra ID** (recommended): an identity with the
     `Cognitive Services OpenAI User` role on the resource, plus a way to
     mint a bearer token (Azure CLI on workstations, managed identity in
     compute).
   - **API key**: an Azure OpenAI key from the resource's "Keys and
     Endpoint" blade.
4. **Codex CLI installed.** `npm i -g @openai/codex`, or use any of the other
   installers listed at <https://github.com/openai/codex>.

---

## Pre-flight check

Before installing Codex or editing any config, prove your Azure deployment
itself can serve the Responses API. This catches the two most common upstream
problems (wrong region, wrong model) in one shot. Replace `YOUR_RESOURCE`
and `YOUR_DEPLOYMENT`.

**Bash:**

```bash
TOKEN=$(az account get-access-token \
  --resource https://cognitiveservices.azure.com \
  --query accessToken -o tsv)
curl -sS -w "\nHTTP %{http_code}\n" \
  -X POST "https://YOUR_RESOURCE.openai.azure.com/openai/responses?api-version=2025-04-01-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"model":"YOUR_DEPLOYMENT","input":"Reply with only OK."}'
```

**PowerShell:**

```powershell
$token = az account get-access-token `
  --resource https://cognitiveservices.azure.com `
  --query accessToken -o tsv
$body = @{ model = "YOUR_DEPLOYMENT"; input = "Reply with only OK." } | ConvertTo-Json
Invoke-RestMethod -Method POST `
  -Uri "https://YOUR_RESOURCE.openai.azure.com/openai/responses?api-version=2025-04-01-preview" `
  -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
  -Body $body
```

You want an `HTTP 200` and an `output[0].content[0].text` of `"OK"`. If you
get `400`, `404`, or `API version not supported`, fix the upstream problem
**first** (see [Troubleshooting](#troubleshooting)); don't proceed to Codex
config.

For API key auth, swap `Authorization: Bearer $TOKEN` for
`api-key: $AZURE_OPENAI_API_KEY`.

---

## Quick start

Edit `YOUR_RESOURCE` and `YOUR_DEPLOYMENT` in the config file before or after
copying; the smoke test will tell you if anything is wrong.

**macOS / Linux (Entra ID):**

```bash
mkdir -p ~/.codex
cp config/config.toml.entra-mac-linux ~/.codex/config.toml
az login
bash scripts/smoke-test.sh
```

**Windows PowerShell (Entra ID):**

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex" | Out-Null
Copy-Item .\config\config.toml.entra-windows "$env:USERPROFILE\.codex\config.toml"
az login
powershell -File .\scripts\smoke-test.ps1
```

**API key (either OS):** copy `config/config.toml.apikey`, then set
`AZURE_OPENAI_API_KEY` **in the same shell** that runs `codex`.

A successful smoke test prints `OK: provider banner shows azure` and
`OK: assistant returned the sentinel`, then exits 0. If it fails, see
[Troubleshooting](#troubleshooting).

---

## What each setting does

```toml
model = "YOUR_DEPLOYMENT"     # Azure deployment name, NOT the model family
model_provider = "azure"      # selects the [model_providers.azure] block
forced_login_method = "api"   # disables "Sign in with ChatGPT" (which hits OpenAI)

[analytics]
enabled = false               # disables the small anonymous health ping to OpenAI

[model_providers.azure]
name = "Azure OpenAI"
base_url = "https://YOUR_RESOURCE.openai.azure.com/openai"
query_params = { api-version = "2025-04-01-preview" }
wire_api = "responses"
```

Key things to internalize:

- **`model` is the deployment name**, not the family. If your Azure
  deployment is called `prod-coding-gpt41`, that is what goes in `model`.
- **`base_url` shape depends on the API path you pick.** Either
  `https://YOUR_RESOURCE.openai.azure.com/openai` with
  `query_params = { api-version = "2025-04-01-preview" }` (this repo's
  default), **or** the newer `https://YOUR_RESOURCE.openai.azure.com/openai/v1`
  form, which rejects `api-version` as a query param. Don't mix them.
- **Private endpoints work.** Point `base_url` at the private FQDN (e.g.
  `https://YOUR_RESOURCE.privatelink.openai.azure.com/openai`); no other
  config changes are needed.

### Telemetry and analytics

Both channels are pre-configured in the sample configs:

- **`[otel]`** (rich OpenTelemetry stream): default off-machine = nothing. See
  [Telemetry routing](#telemetry-routing) below to forward it.
- **`[analytics]`** (anonymous health ping to OpenAI): explicitly set to
  `enabled = false`.

---

## Authentication patterns

All three drop-in TOML files in `config/` already wire one of these. Snippets
below show just the auth block.

### A. Entra ID via Azure CLI (recommended for workstations)

```toml
[model_providers.azure.auth]
command = "az"
args = ["account", "get-access-token",
        "--resource", "https://cognitiveservices.azure.com",
        "--query", "accessToken", "-o", "tsv"]
timeout_ms = 15000
refresh_interval_ms = 1800000
```

On Windows, swap `command = "az"` for `command = "cmd.exe"` with
`args = ["/c", "az account get-access-token ..."]` (Rust's `Command` does
not resolve `.cmd` via PATHEXT). See `config/config.toml.entra-windows` for
the full example.

The signed-in identity needs the **Cognitive Services OpenAI User** role on
the Azure OpenAI resource.

### B. Entra ID via managed identity (Azure VM / AKS / Container Apps)

Replace the `az` command with an IMDS helper script:

```bash
# /opt/codex/get-mi-token.sh
curl -sS -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://cognitiveservices.azure.com" \
  | jq -r .access_token
```

```toml
[model_providers.azure.auth]
command = "/opt/codex/get-mi-token.sh"
refresh_interval_ms = 1800000
```

### C. API key

Set `env_key = "AZURE_OPENAI_API_KEY"` in `[model_providers.azure]` (see
`config/config.toml.apikey`) and export the key in the shell that runs
`codex`. Long-lived secret; prefer Entra for shared/production use.

---

## Troubleshooting

If the smoke test fails, work the table top to bottom. Most first-run
failures are one of these:

| Symptom from `smoke-test` or `codex` | Likely cause | Fix |
| --- | --- | --- |
| `FAIL: provider banner does not show azure` | Codex did not load your `config.toml` | Verify path: `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`). Check `model_provider = "azure"` is set. |
| `dns error: failed to lookup address information: Name does not resolve` on Linux/WSL | `npm i -g @openai/codex` installed the musl binary; its DNS resolver fails against `*.openai.azure.com` | See [Known caveats](#known-caveats) #1: install the GNU binary or pin the IP in `/etc/hosts`. |
| `401` / `403` / `Unauthorized` | Entra: not signed in, wrong tenant, missing RBAC. API key: not set in this shell. | Entra: `az account show` to confirm; assign `Cognitive Services OpenAI User` to the identity. API key: `echo $AZURE_OPENAI_API_KEY` in the same shell that runs `codex`. |
| `404` / `DeploymentNotFound` | `model = ` is the model **family**, not the **deployment name** | Use the Azure deployment name (e.g. `my-prod-gpt41`), not `gpt-4.1`. |
| `API version not supported` | `query_params.api-version` not valid for the region | Try `2025-04-01-preview`; otherwise check the [region's API version list](https://learn.microsoft.com/en-us/azure/ai-services/openai/api-version-deprecation). |
| `400` complaining about Responses API | Deployment is in a region that doesn't expose the Responses API, or the model doesn't support it | Redeploy in a [supported region](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/responses#supported-regions) with a supported model family. |

The `ERROR codex_models_manager::manager: failed to refresh available models`
line at startup is **not** a failure. See [Known caveats](#known-caveats) #1.

---

## Telemetry routing

Forward Codex's OpenTelemetry stream to your own collector (e.g. Application
Insights via an OTel ingestion endpoint):

```toml
[otel]
environment = "prod"
exporter = { otlp-http = {
  endpoint = "https://otel.example.com/v1/logs",
  protocol = "binary",
  headers = { "x-otlp-api-key" = "${OTLP_TOKEN}" }
}}
log_user_prompt = false   # keep prompts redacted by default
```

Use `otlp-grpc` for gRPC collectors. `[analytics] enabled = false` (already
in the samples) separately disables Codex's anonymous health ping to
OpenAI; it must be set at the user level.

### Session history on disk

Codex writes session transcripts to `$CODEX_HOME/history.jsonl` by default.
For compliance-sensitive environments:

```toml
[history]
persistence = "none"
```

---

## Multiple providers (switching between Azure and OpenAI)

`model_provider` selects one provider per invocation. To keep both available
without editing `config.toml`, use **config profiles** (separate files at
`$CODEX_HOME/<name>.config.toml` that overlay the base config).

Keep Azure as the default; put OpenAI in a profile:

```toml
# ~/.codex/openai.config.toml
model = "gpt-5-codex"
model_provider = "openai"
```

```bash
codex                            # default -> Azure
codex --profile openai           # overrides -> OpenAI
codex exec --profile openai ...
```

---

## Enterprise lockdown

To prevent users from accidentally re-pointing Codex back at OpenAI, ship a
managed `requirements.toml` alongside your user-config defaults. Anything
under `requirements.toml` overrides user config. See the
[Codex managed configuration docs](https://developers.openai.com/codex/enterprise/managed-configuration)
for the schema.

A minimal lockdown looks like:

```toml
# requirements.toml (distributed via your endpoint mgmt tooling)
model_provider = "azure"
forced_login_method = "api"

[analytics]
enabled = false
```

---

## Known caveats

1. **Linux/WSL: the musl `npm i -g` binary can't resolve `*.openai.azure.com`.**
   The musl-compiled Codex binary silently fails DNS against Azure hostnames
   (`Name does not resolve`). Workarounds: install the GNU binary from the
   [GitHub Releases page](https://github.com/openai/codex/releases) (needs
   glibc 2.39+, i.e. Ubuntu 24.04+), or pin the IP:
   `ip=$(dig +short YOUR_RESOURCE.openai.azure.com | tail -n1); echo "$ip YOUR_RESOURCE.openai.azure.com" | sudo tee -a /etc/hosts`.
   See [openai/codex#1552](https://github.com/openai/codex/issues/1552).
2. **Cosmetic model-catalog warning.** At startup Codex calls
   `GET /openai/models`; Azure returns a different JSON shape, so Codex logs
   `ERROR codex_models_manager::manager: failed to refresh available models`.
   **Inference is unaffected. Ignore this line.**
3. **"Sign in with ChatGPT" always hits OpenAI.** This guide sets
   `forced_login_method = "api"` to disable that path.
4. **Codex Web (chatgpt.com/codex) is not redirectable.** Only the local
   CLI, IDE extension, and desktop app honor this config.
5. **Region/model matrix matters.** A Responses API deployment must be in a
   supported region with a supported model; Azure docs are the source of
   truth.
6. **One provider per invocation.** See
   [Multiple providers](#multiple-providers-switching-between-azure-and-openai)
   to switch via `--profile`.

---

## Repo layout

```
codex-cli-azure-openai/
├── README.md                              # this file
├── VERIFICATION.md                        # proof-of-test from 2026-06-01
├── LICENSE                                # MIT
├── config/
│   ├── config.toml.entra-mac-linux        # Entra ID, macOS/Linux
│   ├── config.toml.entra-windows          # Entra ID, Windows
│   └── config.toml.apikey                 # API key, any OS
├── scripts/
│   ├── smoke-test.sh                      # one-shot smoke test (bash)
│   └── smoke-test.ps1                     # one-shot smoke test (PowerShell)
└── .gitignore
```

---

## References

- Codex CLI repo: <https://github.com/openai/codex>
- Codex config reference: <https://developers.openai.com/codex/config-reference>
- Codex advanced config (custom providers, profiles, OTel):
  <https://developers.openai.com/codex/config-advanced>
- Azure OpenAI Responses API: <https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/responses>
- Azure OpenAI RBAC roles: <https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/role-based-access-control>

---

## License

[MIT](LICENSE). No warranty; configurations are provided as a starting point.
Verify against your own Azure deployment before relying on them.
