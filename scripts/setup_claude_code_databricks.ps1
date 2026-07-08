#Requires -Version 5.1
<#
.SYNOPSIS
    Bridge the Claude Code CLI to an Azure Databricks-hosted Claude model (Windows).

.DESCRIPTION
    Claude Code speaks only the Anthropic Messages API (POST /v1/messages,
    Anthropic-shaped responses). Databricks Model Serving speaks the OpenAI
    Chat Completions schema at /serving-endpoints/<name>/invocations. This
    script installs a small local LiteLLM proxy that translates between the two,
    points Claude Code at it via %USERPROFILE%\.claude\settings.json, and (on
    Windows) registers a logon Scheduled Task so the proxy starts automatically.

        Claude Code --(/v1/messages)--> LiteLLM (127.0.0.1:PORT) --> Databricks

    It is idempotent. Credentials are read from the repo .env or the environment
    and written only to <ProxyDir>\.env (restricted to the current user).

.EXAMPLE
    scripts\setup_claude_code_databricks.ps1

.EXAMPLE
    $env:DATABRICKS_HOST="https://adb-xxx.azuredatabricks.net"
    $env:DATABRICKS_TOKEN="dapi..."
    $env:DATABRICKS_SERVING_ENDPOINT="databricks-claude-opus-4-8"
    scripts\setup_claude_code_databricks.ps1

.NOTES
    The macOS/Linux equivalent is scripts/setup_claude_code_databricks.sh.
#>
[CmdletBinding()]
param(
    [string]$ProxyDir = (Join-Path $env:USERPROFILE '.claude-databricks'),
    [int]$Port = 4000,
    [string]$MasterKey = 'sk-databricks-local',
    [bool]$AutoStart = $true,
    [string]$TaskName = 'ClaudeDatabricksProxy',
    [string]$ClaudeSettings = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$Endpoint,
    [string]$FastEndpoint,
    [string]$Models,
    [string]$EnvFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Blue }
function Write-Ok   { param([string]$m) Write-Host " ok  $m" -ForegroundColor Green }
function Write-Note { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Die        { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# PowerShell 5.1 only exists on Windows, so a missing $IsWindows means Windows.
$OnWindows = $true
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $OnWindows = [bool]$IsWindows }

$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if (-not $EnvFile) { $EnvFile = Join-Path $Root '.env' }
if (-not $Endpoint) {
    $Endpoint = if ($env:DATABRICKS_SERVING_ENDPOINT) { $env:DATABRICKS_SERVING_ENDPOINT } else { 'databricks-claude-opus-4-8' }
}
# Small/fast "classifier" model Claude Code uses for background tasks
# (ANTHROPIC_SMALL_FAST_MODEL); a lighter/cheaper endpoint than the main one.
if (-not $FastEndpoint) {
    $FastEndpoint = if ($env:DATABRICKS_FAST_ENDPOINT) { $env:DATABRICKS_FAST_ENDPOINT } else { 'databricks-claude-haiku-4-5' }
}
# Selectable main models registered in the proxy so you can switch inside
# Claude Code with `/model <name>`. Space- or comma-separated; override with
# DATABRICKS_MODELS. The default main model is $Endpoint (ANTHROPIC_MODEL).
if (-not $Models) {
    $Models = if ($env:DATABRICKS_MODELS) { $env:DATABRICKS_MODELS } else { 'databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5' }
}

# ---------------------------------------------------------------------------
Write-Step '1/7 Load Databricks credentials'
$DbxHost = $env:DATABRICKS_HOST
$DbxToken = $env:DATABRICKS_TOKEN
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
            switch ($k) {
                'DATABRICKS_HOST'  { if (-not $DbxHost)  { $DbxHost = $v } }
                'DATABRICKS_TOKEN' { if (-not $DbxToken) { $DbxToken = $v } }
                'DATABRICKS_SERVING_ENDPOINT' { if (-not $env:DATABRICKS_SERVING_ENDPOINT) { $Endpoint = $v } }
                'DATABRICKS_FAST_ENDPOINT' { if (-not $env:DATABRICKS_FAST_ENDPOINT) { $FastEndpoint = $v } }
                'DATABRICKS_MODELS' { if (-not $env:DATABRICKS_MODELS) { $Models = $v } }
            }
        }
    }
    Write-Ok "loaded $EnvFile"
}
else {
    Write-Note "no $EnvFile - expecting DATABRICKS_HOST/DATABRICKS_TOKEN in the environment"
}
if (-not $DbxHost)  { Die 'DATABRICKS_HOST is required (in .env or the environment)' }
if (-not $DbxToken) { Die 'DATABRICKS_TOKEN is required (in .env or the environment)' }
$ApiBase = $DbxHost.TrimEnd('/') + '/serving-endpoints'
Write-Ok "endpoint: $Endpoint   fast: $FastEndpoint   base: $ApiBase"
Write-Ok "selectable models (/model): $Models"

# ---------------------------------------------------------------------------
Write-Step '2/7 Preflight'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $cv = (& claude --version 2>$null | Select-Object -First 1)
    Write-Ok "claude CLI: $cv"
}
else {
    Write-Note 'claude CLI not on PATH - install it, then re-run (setup still continues)'
}

$UseUv = [bool](Get-Command uv -ErrorAction SilentlyContinue)
$PyExe = $null
if (-not $UseUv) {
    foreach ($cand in @('python', 'python3', 'py')) {
        $c = Get-Command $cand -ErrorAction SilentlyContinue
        if ($c) { $PyExe = $c.Source; break }
    }
    if (-not $PyExe) { Die "need either 'uv' or 'python' to create the proxy environment" }
}
if ($UseUv) { Write-Ok 'using uv for the Python environment' } else { Write-Ok "using python venv + pip ($PyExe)" }

# ---------------------------------------------------------------------------
Write-Step "3/7 Proxy environment at $ProxyDir"
New-Item -ItemType Directory -Force -Path $ProxyDir | Out-Null
$Venv = Join-Path $ProxyDir '.venv'
$BinDir = if ($OnWindows) { Join-Path $Venv 'Scripts' } else { Join-Path $Venv 'bin' }
$VenvPy = Join-Path $BinDir ($(if ($OnWindows) { 'python.exe' } else { 'python' }))
$VenvLitellm = Join-Path $BinDir ($(if ($OnWindows) { 'litellm.exe' } else { 'litellm' }))

if ((Test-Path $VenvLitellm) -and (-not $Force)) {
    Write-Ok 'litellm already installed (-Force to reinstall)'
}
else {
    if ($UseUv) {
        if (-not (Test-Path $Venv)) { & uv venv $Venv --python 3.12 }
        & uv pip install --python $VenvPy --quiet 'litellm[proxy]'
    }
    else {
        if (-not (Test-Path $Venv)) { & $PyExe -m venv $Venv }
        & $VenvPy -m pip install --quiet --upgrade pip
        & $VenvPy -m pip install --quiet 'litellm[proxy]'
    }
    if ($LASTEXITCODE -ne 0) { Die 'litellm install failed' }
    Write-Ok 'installed litellm[proxy]'
}

# ---------------------------------------------------------------------------
Write-Step '4/7 Write proxy config, credentials, and start script'

# Register every selectable main model (plus the small/fast model) as its own
# entry so Claude Code's /model <name> resolves each to the right Databricks
# endpoint. De-duplicate, default first, fast last; the catch-all "*" then
# routes any unrecognized name to the default main endpoint.
$modelTokens = (@($Endpoint) + ($Models -split '[,\s]+') + @($FastEndpoint)) |
    Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
$reg = @()
foreach ($m in $modelTokens) { if ($reg -notcontains $m) { $reg += $m } }

$entryTemplate = @'
  - model_name: __M__
    litellm_params:
      model: databricks/__M__
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
'@
$ModelEntries = (($reg | ForEach-Object { $entryTemplate.Replace('__M__', $_) }) -join "`n")
$regList = $reg -join ' '

$Config = @"
# LiteLLM proxy: exposes an Anthropic /v1/messages endpoint that Claude Code
# talks to, and translates each request to Azure Databricks serving endpoints.
# Registered models (switch inside Claude Code with /model <name>):
#   $regList
# Default main (ANTHROPIC_MODEL): $Endpoint
# Small/fast classifier (ANTHROPIC_SMALL_FAST_MODEL): $FastEndpoint
# Credentials are injected from the sibling .env at runtime (DATABRICKS_API_KEY /
# DATABRICKS_API_BASE); no secrets live here.
model_list:
$ModelEntries
  # Catch-all: any unrecognized model name is routed to the default main endpoint.
  - model_name: "*"
    litellm_params:
      model: databricks/$Endpoint
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE

litellm_settings:
  drop_params: true
  # Strip Anthropic 'thinking' content Claude Code replays (Databricks rejects
  # it: "messages.N.thinking_blocks: Extra inputs are not permitted").
  callbacks: custom_handlers.proxy_handler_instance

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
"@
Set-Content -Path (Join-Path $ProxyDir 'config.yaml') -Value $Config -Encoding utf8
Write-Ok "wrote $ProxyDir\config.yaml"

$CustomHandlers = @'
"""LiteLLM proxy hook: make Claude Code requests compatible with Databricks.

Two Anthropic-isms that the Databricks serving endpoint rejects are fixed here,
in a single pre-call hook, before the upstream `/invocations` request:

1. `thinking_blocks` / `reasoning_content` - Claude Code (extended thinking)
   replays prior assistant 'thinking' blocks in the conversation history.
   Databricks rejects them with
   `messages.N.thinking_blocks: Extra inputs are not permitted`.

2. `stop_sequences` - Claude Code (including its small/fast "classifier"
   background calls) sends the Anthropic `stop_sequences` field. Databricks
   rejects it with `Cannot specify parameter stop_sequences, use stop instead.`
   so we translate it to the OpenAI-style `stop`.
"""

from litellm.integrations.custom_logger import CustomLogger

_THINKING_TYPES = {"thinking", "redacted_thinking"}


class DatabricksCompatHook(CustomLogger):
    @staticmethod
    def _fix_stop(container):
        """Translate Anthropic `stop_sequences` to the OpenAI-style `stop`.

        Databricks also rejects whitespace-only stop sequences, so drop those;
        if none remain, omit `stop` entirely rather than send an invalid value.
        """
        if not isinstance(container, dict) or "stop_sequences" not in container:
            return
        seq = container.pop("stop_sequences")
        if isinstance(seq, str):
            seq = [seq]
        if isinstance(seq, list):
            seq = [s for s in seq if isinstance(s, str) and s.strip()]
        else:
            seq = None
        if seq and not container.get("stop"):
            container["stop"] = seq

    def _clean(self, data):
        if not isinstance(data, dict):
            return data
        # stop_sequences can sit at the top level and/or under optional_params.
        self._fix_stop(data)
        self._fix_stop(data.get("optional_params"))
        messages = data.get("messages")
        if isinstance(messages, list):
            for msg in messages:
                if not isinstance(msg, dict):
                    continue
                msg.pop("thinking_blocks", None)
                msg.pop("reasoning_content", None)
                content = msg.get("content")
                if isinstance(content, list):
                    filtered = [
                        block
                        for block in content
                        if not (isinstance(block, dict) and block.get("type") in _THINKING_TYPES)
                    ]
                    # Never leave an assistant turn with empty content.
                    msg["content"] = filtered if filtered else ""
        return data

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        return self._clean(data)


proxy_handler_instance = DatabricksCompatHook()
'@
Set-Content -Path (Join-Path $ProxyDir 'custom_handlers.py') -Value $CustomHandlers -Encoding utf8
Write-Ok "wrote $ProxyDir\custom_handlers.py"

$EnvContent = @"
# Auto-generated by setup_claude_code_databricks.ps1 - contains a secret.
DATABRICKS_API_KEY=$DbxToken
DATABRICKS_API_BASE=$ApiBase
LITELLM_MASTER_KEY=$MasterKey
"@
$EnvPath = Join-Path $ProxyDir '.env'
Set-Content -Path $EnvPath -Value $EnvContent -Encoding ascii
if ($OnWindows) {
    # Restrict to the current user (equivalent of chmod 600).
    & icacls $EnvPath /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
}
else {
    & chmod 600 $EnvPath
}
Write-Ok "wrote $ProxyDir\.env (restricted to current user)"

$LogPath = Join-Path $ProxyDir 'proxy.log'
$StartTemplate = @'
# Auto-generated. Loads credentials from .env and starts the LiteLLM proxy.
$ErrorActionPreference = 'Stop'
Get-Content '__ENV__' | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
    }
}
& '__LITELLM__' --config '__CONFIG__' --host 127.0.0.1 --port __PORT__ *>> '__LOG__'
'@
$StartScript = Join-Path $ProxyDir 'start-proxy.ps1'
$StartTemplate = $StartTemplate.
    Replace('__ENV__', $EnvPath).
    Replace('__LITELLM__', $VenvLitellm).
    Replace('__CONFIG__', (Join-Path $ProxyDir 'config.yaml')).
    Replace('__LOG__', $LogPath).
    Replace('__PORT__', "$Port")
Set-Content -Path $StartScript -Value $StartTemplate -Encoding utf8
Write-Ok "wrote $StartScript"

# ---------------------------------------------------------------------------
Write-Step "5/7 Point Claude Code at the proxy ($ClaudeSettings)"
$SettingsDir = Split-Path -Parent $ClaudeSettings
if ($SettingsDir) { New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null }
if (Test-Path $ClaudeSettings) {
    Copy-Item $ClaudeSettings "$ClaudeSettings.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Ok 'backed up existing settings'
}
$env:CC_SETTINGS = $ClaudeSettings
$env:CC_PORT = "$Port"
$env:CC_KEY = $MasterKey
$env:CC_ENDPOINT = $Endpoint
$env:CC_ENDPOINT_FAST = $FastEndpoint
$PyMerge = @'
import json, os
path = os.environ["CC_SETTINGS"]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
env = data.get("env") or {}
env.update({
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:" + os.environ["CC_PORT"],
    "ANTHROPIC_AUTH_TOKEN": os.environ["CC_KEY"],
    "ANTHROPIC_MODEL": os.environ["CC_ENDPOINT"],
    "ANTHROPIC_SMALL_FAST_MODEL": os.environ["CC_ENDPOINT_FAST"],
})
data["env"] = env
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  merged env block into", path)
'@
$TmpPy = Join-Path ([System.IO.Path]::GetTempPath()) "cc_merge_$PID.py"
Set-Content -Path $TmpPy -Value $PyMerge -Encoding utf8
try { & $VenvPy $TmpPy } finally { Remove-Item $TmpPy -ErrorAction SilentlyContinue }
if ($LASTEXITCODE -ne 0) { Die 'failed to update Claude Code settings' }
Write-Ok 'Claude Code settings updated'

# ---------------------------------------------------------------------------
Write-Step '6/7 Start the proxy'
function Test-ProxyHealth {
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$Port/health/liveliness" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    }
    catch { return $false }
}

$PsExe = (Get-Process -Id $PID).Path
if (-not $PsExe) { $PsExe = if ($OnWindows) { 'powershell.exe' } else { 'pwsh' } }

if ($AutoStart) {
    if ($OnWindows) {
        $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$StartScript`""
        $action = New-ScheduledTaskAction -Execute $PsExe -Argument $arg
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Write-Ok "scheduled task '$TaskName' registered (runs at logon, restarts on failure)"
    }
    else {
        Write-Note 'auto-start Scheduled Task is Windows-only; starting a background process for this session'
        Start-Process -FilePath $PsExe -ArgumentList @('-NoProfile', '-File', $StartScript) | Out-Null
        Write-Ok 'proxy started (background process)'
    }
}
else {
    Write-Note "AutoStart disabled - start it yourself: `"$PsExe`" -File `"$StartScript`""
}

# ---------------------------------------------------------------------------
Write-Step '7/7 Verify'
if ($AutoStart) {
    $healthy = $false
    # A fresh venv's first litellm import can be slow, so allow up to 60s.
    for ($i = 0; $i -lt 60; $i++) { if (Test-ProxyHealth) { $healthy = $true; break }; Start-Sleep -Seconds 1 }
    if (-not $healthy) {
        Write-Note "proxy not healthy yet after 60s (cold start can be slow) - check $LogPath, then retry: curl http://127.0.0.1:$Port/health/liveliness"
    }
    else {
        Write-Ok "proxy healthy on 127.0.0.1:$Port"
        try {
            $body = @{
                model      = $Endpoint
                max_tokens = 20
                messages   = @(@{ role = 'user'; content = 'Reply with: OK' })
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod "http://127.0.0.1:$Port/v1/messages" -Method Post `
                -Headers @{ Authorization = "Bearer $MasterKey"; 'anthropic-version' = '2023-06-01' } `
                -ContentType 'application/json' -Body $body
            if ($resp.type -eq 'message') {
                Write-Ok '/v1/messages round-trip OK (native Anthropic response from Databricks)'
            }
            else {
                Write-Note "/v1/messages test did not return an Anthropic message"
            }
            if ($FastEndpoint -ne $Endpoint) {
                $bodyFast = @{
                    model      = $FastEndpoint
                    max_tokens = 20
                    messages   = @(@{ role = 'user'; content = 'Reply with: OK' })
                } | ConvertTo-Json -Depth 6
                $respFast = Invoke-RestMethod "http://127.0.0.1:$Port/v1/messages" -Method Post `
                    -Headers @{ Authorization = "Bearer $MasterKey"; 'anthropic-version' = '2023-06-01' } `
                    -ContentType 'application/json' -Body $bodyFast
                if ($respFast.type -eq 'message') {
                    Write-Ok "small/fast model '$FastEndpoint' round-trip OK"
                }
                else {
                    Write-Note "small/fast model '$FastEndpoint' did not return an Anthropic message"
                }
            }
            foreach ($m in ($Models -split '[,\s]+' | Where-Object { $_ -and $_.Trim() })) {
                $m = $m.Trim()
                if ($m -ne $Endpoint -and $m -ne $FastEndpoint) {
                    $bodyM = @{
                        model      = $m
                        max_tokens = 20
                        messages   = @(@{ role = 'user'; content = 'Reply with: OK' })
                    } | ConvertTo-Json -Depth 6
                    $respM = Invoke-RestMethod "http://127.0.0.1:$Port/v1/messages" -Method Post `
                        -Headers @{ Authorization = "Bearer $MasterKey"; 'anthropic-version' = '2023-06-01' } `
                        -ContentType 'application/json' -Body $bodyM
                    if ($respM.type -eq 'message') {
                        Write-Ok "model '$m' round-trip OK (selectable via /model)"
                    }
                    else {
                        Write-Note "model '$m' did not return an Anthropic message"
                    }
                }
            }
        }
        catch {
            Write-Note "/v1/messages test failed: $($_.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Ok 'Done.'
Write-Host '  - Open a new terminal and run:  claude'
Write-Host "  - Switch model in Claude Code:  /model <name>   (registered: $Models)"
Write-Host "  - Manual start (if the task is off):  `"$PsExe`" -File `"$StartScript`""
Write-Host "  - Manage task:  Get-ScheduledTask -TaskName '$TaskName' ; Stop-ScheduledTask -TaskName '$TaskName'"
Write-Host "  - Logs:  $LogPath"
Write-Host '  - Docs:  docs/claude-code-databricks.md'
