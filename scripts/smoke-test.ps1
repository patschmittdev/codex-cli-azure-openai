# Smoke test: one-shot `codex exec` that asserts the provider banner says
# `azure` and that the assistant returned a unique sentinel string.
# Exits 0 on success, non-zero on failure.
$ErrorActionPreference = 'Stop'

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Error "codex not on PATH. Install with: npm i -g @openai/codex"
    exit 2
}

$home_dir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$env:USERPROFILE\.codex" }
$config = Join-Path $home_dir 'config.toml'
if (-not (Test-Path $config)) {
    Write-Error "No config at $config. Copy one from config/ first."
    exit 2
}

Write-Host "Using config: $config"
Write-Host "Codex version: $(codex --version)"
Write-Host ""

# Use a unique sentinel that does NOT appear in the prompt itself, so a
# request failure cannot falsely satisfy the check by echoing the prompt.
$sentinel = 'CODEX_AZURE_SMOKE_OK'

$ErrorActionPreference = 'Continue'
$out = codex exec --skip-git-repo-check --sandbox read-only --color never `
    "Reply with exactly the token $sentinel on a line by itself and nothing else." 2>&1 | Out-String
$status = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

$out -split "`n" | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
Write-Host ""

if ($status -ne 0) {
    Write-Error "FAIL: codex exited with status $status"
    exit 1
}

# Strict line-anchored matches; -split avoids the prompt echo false-positive.
$lines = ($out -replace "`r", '') -split "`n"
$providerOk = $lines | Where-Object { $_ -match '^provider:\s*azure\s*$' }
$sentinelOk = $lines | Where-Object { $_ -ceq $sentinel }

if ($providerOk) { Write-Host "OK: provider banner shows azure" }
else { Write-Error "FAIL: provider banner does not show azure"; exit 1 }

if ($sentinelOk) { Write-Host "OK: assistant returned the sentinel"; exit 0 }
else { Write-Error "FAIL: did not see sentinel '$sentinel' on its own line"; exit 1 }
