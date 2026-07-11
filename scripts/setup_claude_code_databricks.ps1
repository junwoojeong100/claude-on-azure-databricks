#Requires -Version 5.1
<#
.SYNOPSIS
    Configure Claude Code to call Azure Databricks' native Anthropic API.

.DESCRIPTION
    Azure Databricks exposes an Anthropic-compatible endpoint at:

        https://<workspace>/serving-endpoints/anthropic/v1/messages

    Claude Code can use this endpoint directly. No LiteLLM proxy, Python
    environment, local port, or auto-start service is required.

    This script checks prerequisites and ambient credentials, verifies the
    endpoint and model fallbacks, stores the Databricks token in a
    user-restricted file, configures apiKeyHelper, model aliases, beta
    filtering, and WebSearch deny, disables the legacy LiteLLM Scheduled Task
    if present, and runs an end-to-end test.

.EXAMPLE
    .\scripts\setup_claude_code_databricks.ps1

.EXAMPLE
    $env:DATABRICKS_HOST = 'https://adb-xxx.azuredatabricks.net'
    $env:DATABRICKS_TOKEN = 'dapi...'
    $env:DATABRICKS_SERVING_ENDPOINT = 'databricks-claude-opus-4-8'
    .\scripts\setup_claude_code_databricks.ps1
#>
[CmdletBinding()]
param(
    [Alias('ProxyDir')]
    [string]$StateDir = (Join-Path $HOME '.claude-databricks'),
    [string]$ClaudeSettings = (Join-Path (Join-Path $HOME '.claude') 'settings.json'),
    [string]$Endpoint,
    [string]$FastEndpoint,
    [string]$Models,
    [string]$EnvFile,
    [string]$LegacyTaskName = 'ClaudeDatabricksProxy'
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host " ok  $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Stop-WithError {
    param([string]$Message)
    Write-Host "[x] $Message" -ForegroundColor Red
    exit 1
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Remove-JsonProperty {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Test-JsonObject {
    param([AllowNull()] $Value)
    return $null -ne $Value -and $Value.GetType() -eq [System.Management.Automation.PSCustomObject]
}

function Test-NativeModel {
    param([Parameter(Mandatory)] [string]$Model)

    $body = @{
        model      = $Model
        max_tokens = 16
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
    } | ConvertTo-Json -Depth 8

    try {
        $response = Invoke-RestMethod "$script:AnthropicBaseUrl/v1/messages" -Method Post `
            -Headers @{
                Authorization       = "Bearer $script:DbxToken"
                'anthropic-version' = '2023-06-01'
            } `
            -ContentType 'application/json' `
            -Body $body
        $script:LastNativeError = $null
        return ($response.type -eq 'message')
    }
    catch {
        $script:LastNativeError = $_.ErrorDetails.Message
        if (-not $script:LastNativeError) {
            $script:LastNativeError = $_.Exception.Message
        }
        return $false
    }
}

$OnWindows = $true
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    $OnWindows = [bool]$IsWindows
}

$Root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if (-not $EnvFile) {
    $EnvFile = Join-Path $Root '.env'
}

Write-Step '1/6 Load Databricks credentials'
$DbxHost = $env:DATABRICKS_HOST
$DbxToken = $env:DATABRICKS_TOKEN

if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            switch ($key) {
                'DATABRICKS_HOST' {
                    if (-not $DbxHost) { $DbxHost = $value }
                }
                'DATABRICKS_TOKEN' {
                    if (-not $DbxToken) { $DbxToken = $value }
                }
                'DATABRICKS_SERVING_ENDPOINT' {
                    if (-not $Endpoint -and -not $env:DATABRICKS_SERVING_ENDPOINT) {
                        $Endpoint = $value
                    }
                }
                'DATABRICKS_FAST_ENDPOINT' {
                    if (-not $FastEndpoint -and -not $env:DATABRICKS_FAST_ENDPOINT) {
                        $FastEndpoint = $value
                    }
                }
                'DATABRICKS_MODELS' {
                    if (-not $Models -and -not $env:DATABRICKS_MODELS) {
                        $Models = $value
                    }
                }
            }
        }
    }
    Write-Ok "loaded $EnvFile"
}
else {
    Write-Note "no $EnvFile; using environment variables"
}

if (-not $DbxHost) { Stop-WithError 'DATABRICKS_HOST is required' }
if (-not $DbxToken) { Stop-WithError 'DATABRICKS_TOKEN is required' }

if (-not $Endpoint) {
    $Endpoint = if ($env:DATABRICKS_SERVING_ENDPOINT) {
        $env:DATABRICKS_SERVING_ENDPOINT
    }
    else {
        'databricks-claude-opus-4-8'
    }
}
if (-not $FastEndpoint -and -not $env:DATABRICKS_FAST_ENDPOINT -and (Test-Path $ClaudeSettings)) {
    try {
        $ExistingSettings = Get-Content -Raw $ClaudeSettings | ConvertFrom-Json
    }
    catch {
        Stop-WithError "Invalid JSON in $ClaudeSettings`: $($_.Exception.Message)"
    }
    if (
        $null -ne $ExistingSettings -and
        $ExistingSettings.PSObject.Properties['env'] -and
        $null -ne $ExistingSettings.env -and
        $ExistingSettings.env.PSObject.Properties['ANTHROPIC_SMALL_FAST_MODEL']
    ) {
        $LegacyFastEndpoint = [string]$ExistingSettings.env.ANTHROPIC_SMALL_FAST_MODEL
        if ($LegacyFastEndpoint) {
            $FastEndpoint = $LegacyFastEndpoint
            Write-Ok "migrating legacy ANTHROPIC_SMALL_FAST_MODEL='$LegacyFastEndpoint'"
        }
    }
}
if (-not $FastEndpoint) {
    $FastEndpoint = if ($env:DATABRICKS_FAST_ENDPOINT) {
        $env:DATABRICKS_FAST_ENDPOINT
    }
    else {
        'databricks-claude-haiku-4-5'
    }
}
if (-not $Models) {
    $Models = if ($env:DATABRICKS_MODELS) {
        $env:DATABRICKS_MODELS
    }
    else {
        'databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5 databricks-claude-fable-5'
    }
}

$AnthropicBaseUrl = $DbxHost.TrimEnd('/') + '/serving-endpoints/anthropic'
Write-Ok "native Anthropic API: $AnthropicBaseUrl"
Write-Ok "default model: $Endpoint   Haiku/lightweight background: $FastEndpoint"

Write-Step '2/6 Preflight'
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Stop-WithError 'Claude Code is not installed or not on PATH'
}
if ($env:ANTHROPIC_AUTH_TOKEN -or $env:ANTHROPIC_API_KEY) {
    Stop-WithError 'clear ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY in this shell before setup; ambient credentials override apiKeyHelper'
}
$ClaudeVersion = (& claude --version 2>$null | Select-Object -First 1)
Write-Ok "Claude Code: $ClaudeVersion"
if ($ClaudeVersion -match '(\d+\.\d+\.\d+)' -and
    [version]$Matches[1] -lt [version]'2.1.197') {
    Write-Note 'Claude Code 2.1.197+ is recommended for the default Sonnet 5 mapping'
}

Write-Step '3/6 Verify native Anthropic API'
if (-not (Test-NativeModel -Model $Endpoint)) {
    if ($LastNativeError) { Write-Host $LastNativeError -ForegroundColor Red }
    Stop-WithError "native Anthropic request failed for '$Endpoint'"
}
Write-Ok "main model '$Endpoint' returned an Anthropic message"

if ($FastEndpoint -ne $Endpoint) {
    if (Test-NativeModel -Model $FastEndpoint) {
        Write-Ok "Haiku/lightweight background model '$FastEndpoint' returned an Anthropic message"
    }
    else {
        Write-Note "Haiku/lightweight background model '$FastEndpoint' failed; using '$Endpoint'"
        $FastEndpoint = $Endpoint
    }
}

$ValidatedModels = @($Endpoint, $FastEndpoint)
foreach ($model in ($Models -split '[,\s]+' | Where-Object { $_ -and $_.Trim() })) {
    $model = $model.Trim()
    if ($model -eq $Endpoint -or $model -eq $FastEndpoint) {
        continue
    }
    if (Test-NativeModel -Model $model) {
        Write-Ok "selectable model '$model' returned an Anthropic message"
        $ValidatedModels += $model
    }
    else {
        Write-Note "selectable model '$model' failed validation; using a validated family fallback"
    }
}
$ValidatedModels = @($ValidatedModels | Select-Object -Unique)

Write-Step '4/6 Store credential helper'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$StateDir = (Resolve-Path $StateDir).Path
$TokenFile = Join-Path $StateDir '.env'
$TokenHelper = Join-Path $StateDir 'get-token.ps1'

Set-Content -Path $TokenFile -Encoding ascii -Value @(
    '# Used only by the Claude Code apiKeyHelper. Contains a Databricks credential.'
    "DATABRICKS_TOKEN=$DbxToken"
)

$TokenHelperContent = @'
$ErrorActionPreference = 'Stop'
$tokenFile = Join-Path $PSScriptRoot '.env'
foreach ($line in Get-Content $tokenFile) {
    if ($line -match '^DATABRICKS_TOKEN=(.*)$') {
        [Console]::Out.Write($Matches[1])
        exit 0
    }
}
Write-Error "DATABRICKS_TOKEN is missing from $tokenFile"
exit 1
'@
Set-Content -Path $TokenHelper -Encoding utf8 -Value $TokenHelperContent

if ($OnWindows) {
    & icacls $TokenFile /inheritance:r /grant:r "${env:USERNAME}:(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to restrict ACLs on $TokenFile"
    }
    & icacls $TokenHelper /inheritance:r /grant:r "${env:USERNAME}:(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to restrict ACLs on $TokenHelper"
    }
    $HelperShell = 'powershell.exe'
}
else {
    & chmod 600 $TokenFile
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to set mode 0600 on $TokenFile"
    }
    & chmod 700 $TokenHelper
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "failed to set mode 0700 on $TokenHelper"
    }
    $HelperShell = 'pwsh'
}
$ApiKeyHelper = "$HelperShell -NoProfile -ExecutionPolicy Bypass -File `"$TokenHelper`""
Write-Ok "credential stored in $TokenFile"

Write-Step '5/6 Configure Claude Code'
$SettingsDir = Split-Path -Parent $ClaudeSettings
if ($SettingsDir) {
    New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
}

if (Test-Path $ClaudeSettings) {
    Copy-Item $ClaudeSettings "$ClaudeSettings.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Ok 'backed up existing Claude settings'
    try {
        $Settings = Get-Content $ClaudeSettings -Raw | ConvertFrom-Json
    }
    catch {
        Stop-WithError "invalid JSON in $ClaudeSettings`: $($_.Exception.Message)"
    }
}
else {
    $Settings = [pscustomobject]@{}
}

if (-not (Test-JsonObject $Settings)) {
    Stop-WithError "$ClaudeSettings must contain a JSON object"
}

if ($Settings.PSObject.Properties['env']) {
    $ClaudeEnv = $Settings.env
    if (-not (Test-JsonObject $ClaudeEnv)) {
        Stop-WithError "$ClaudeSettings`: 'env' must be a JSON object"
    }
}
else {
    $ClaudeEnv = [pscustomobject]@{}
}

Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_AUTH_TOKEN'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_API_KEY'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_SMALL_FAST_MODEL'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_OPUS_MODEL'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_SONNET_MODEL'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_HAIKU_MODEL'
Remove-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_FABLE_MODEL'
Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_BASE_URL' -Value $AnthropicBaseUrl
Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_MODEL' -Value $Endpoint
Set-JsonProperty -Object $ClaudeEnv -Name 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS' -Value '1'
Set-JsonProperty -Object $ClaudeEnv -Name 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS' -Value '900000'

if ($Settings.PSObject.Properties['permissions']) {
    $Permissions = $Settings.permissions
    if (-not (Test-JsonObject $Permissions)) {
        Stop-WithError "$ClaudeSettings`: 'permissions' must be a JSON object"
    }
}
else {
    $Permissions = [pscustomobject]@{}
}

if ($Permissions.PSObject.Properties['deny']) {
    if ($null -eq $Permissions.deny) {
        $DenyRules = @()
    }
    elseif ($Permissions.deny -is [array]) {
        $DenyRules = @($Permissions.deny)
    }
    else {
        Stop-WithError "$ClaudeSettings`: 'permissions.deny' must be a JSON array"
    }
}
else {
    $DenyRules = @()
}
if ($DenyRules -notcontains 'WebSearch') {
    $DenyRules += 'WebSearch'
}
Set-JsonProperty -Object $Permissions -Name 'deny' -Value $DenyRules

$DefaultOpus = ''
$DefaultSonnet = ''
$DefaultHaiku = $FastEndpoint
$DefaultFable = ''
foreach ($model in $ValidatedModels) {
    $model = $model.Trim()
    if (-not $DefaultOpus -and $model -like '*opus*') { $DefaultOpus = $model }
    if (-not $DefaultSonnet -and $model -like '*sonnet*') { $DefaultSonnet = $model }
    if (-not $DefaultFable -and $model -like '*fable*') { $DefaultFable = $model }
}
if (-not $DefaultOpus) { $DefaultOpus = $Endpoint }
if (-not $DefaultSonnet) { $DefaultSonnet = $Endpoint }

if ($DefaultOpus) {
    Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_OPUS_MODEL' -Value $DefaultOpus
}
if ($DefaultSonnet) {
    Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_SONNET_MODEL' -Value $DefaultSonnet
}
if ($DefaultHaiku) {
    Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_HAIKU_MODEL' -Value $DefaultHaiku
}
if ($DefaultFable) {
    Set-JsonProperty -Object $ClaudeEnv -Name 'ANTHROPIC_DEFAULT_FABLE_MODEL' -Value $DefaultFable
}

Set-JsonProperty -Object $Settings -Name 'apiKeyHelper' -Value $ApiKeyHelper
Set-JsonProperty -Object $Settings -Name 'env' -Value $ClaudeEnv
Set-JsonProperty -Object $Settings -Name 'permissions' -Value $Permissions
$SettingsJson = ($Settings | ConvertTo-Json -Depth 20) + [Environment]::NewLine
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ClaudeSettings, $SettingsJson, $Utf8NoBom)
Write-Ok "configured direct Databricks access in $ClaudeSettings"

if ($OnWindows) {
    $LegacyTask = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
    if ($LegacyTask) {
        Stop-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false
        Write-Ok "removed legacy LiteLLM Scheduled Task '$LegacyTaskName'"
    }
}
if ((Test-Path (Join-Path $StateDir 'config.yaml')) -or (Test-Path (Join-Path $StateDir '.venv'))) {
    Write-Note "legacy LiteLLM files remain in $StateDir but are no longer used"
}

Write-Step '6/6 Claude Code end-to-end test'
$SavedConfigDir = $env:CLAUDE_CONFIG_DIR
$VerifyDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-direct-$PID"
New-Item -ItemType Directory -Force -Path $VerifyDir | Out-Null
Copy-Item $ClaudeSettings (Join-Path $VerifyDir 'settings.json') -Force
$env:CLAUDE_CONFIG_DIR = $VerifyDir

try {
    $RawOutput = (& claude --model $Endpoint `
        -p 'Reply with exactly: DIRECT OK' --output-format json 2>&1 | Out-String).Trim()
    $ClaudeExit = $LASTEXITCODE
}
finally {
    if ($null -ne $SavedConfigDir) {
        $env:CLAUDE_CONFIG_DIR = $SavedConfigDir
    }
    else {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $VerifyDir -ErrorAction SilentlyContinue
}

try {
    $ClaudeResult = $RawOutput | ConvertFrom-Json
}
catch {
    Write-Host $RawOutput -ForegroundColor Red
    Stop-WithError 'Claude Code returned invalid JSON'
}

if ($ClaudeExit -ne 0 -or $ClaudeResult.is_error -or $ClaudeResult.result -notmatch 'DIRECT OK') {
    Write-Host $RawOutput -ForegroundColor Red
    Stop-WithError 'Claude Code direct Databricks test failed'
}
Write-Ok 'Claude Code reached Databricks directly without LiteLLM'

Write-Host ''
Write-Ok 'Done.'
Write-Host '  - Start Claude Code:  claude'
Write-Host '  - Switch model:      /model'
Write-Host "  - Native API:        $AnthropicBaseUrl"
Write-Host "  - Credential helper: $TokenHelper"
Write-Host '  - Legacy LiteLLM files, if any, are inert and can be removed after review.'
