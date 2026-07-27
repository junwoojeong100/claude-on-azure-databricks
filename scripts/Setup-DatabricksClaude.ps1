[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:RG) { $env:RG } else { 'rg-databricks-claude' }),
    [string]$Location = $(if ($env:LOCATION) { $env:LOCATION } else { 'eastus2' }),
    [string]$Workspace = $(if ($env:WORKSPACE) { $env:WORKSPACE } else { 'ws-databricks-claude' }),
    [string]$Sku = $(if ($env:SKU) { $env:SKU } else { 'premium' }),
    [string]$Endpoint = $(if ($env:DATABRICKS_SERVING_ENDPOINT) { $env:DATABRICKS_SERVING_ENDPOINT } else { 'databricks-claude-opus-5' }),
    [string]$FallbackEndpoint = $(if ($env:FALLBACK) { $env:FALLBACK } else { 'databricks-meta-llama-3-3-70b-instruct' }),
    [int]$PatLifetimeSeconds = $(if ($env:PAT_LIFETIME_SECONDS) { [int]$env:PAT_LIFETIME_SECONDS } else { 7776000 }),
    [bool]$RotatePat = ($env:ROTATE_PAT -eq '1'),
    [bool]$ConfigureClaudeCode = ($env:CONFIGURE_CLAUDE_CODE -ne '0'),
    [ValidateSet('user', 'project')]
    [string]$ClaudeCodeScope = $(if ($env:CLAUDE_CODE_SCOPE) { $env:CLAUDE_CODE_SCOPE } else { 'user' }),
    [bool]$RunAgent = ($env:RUN_AGENT -eq '1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$EnvPath = Join-Path $RepoRoot '.env'
$ConfiguratorPath = Join-Path $PSScriptRoot 'configure_claude_code.py'
$AgentPython = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$AgentSample = Join-Path $RepoRoot 'src\agent_sample.py'
$DatabricksAadResource = '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d'
$EndpointExplicit = (
    $PSBoundParameters.ContainsKey('Endpoint') -or
    [bool]$env:DATABRICKS_SERVING_ENDPOINT
)

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host " ok $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Protect-File {
    param([string]$Path)

    $UserName = $env:USERNAME
    if (-not $UserName) {
        throw 'USERNAME is required to restrict file access.'
    }
    & icacls $Path /inheritance:r /grant:r "${UserName}:(M)" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restrict access to $Path."
    }
}

function Invoke-Az {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $Output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
    return $Output
}

function Test-AzResource {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & az @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [string]$Uri,
        [string]$Token,
        [string]$Body,
        [hashtable]$AdditionalHeaders
    )

    $Parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $Token" }
        UseBasicParsing = $true
    }
    if ($Body) {
        $Parameters.ContentType = 'application/json'
        $Parameters.Body = $Body
    }
    if ($AdditionalHeaders) {
        foreach ($HeaderName in $AdditionalHeaders.Keys) {
            $Parameters.Headers[$HeaderName] = $AdditionalHeaders[$HeaderName]
        }
    }

    try {
        $Response = Invoke-WebRequest @Parameters
        return [pscustomobject]@{
            Status = [int]$Response.StatusCode
            Body = $Response.Content
        }
    } catch {
        $Status = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $Status = [int]$_.Exception.Response.StatusCode
        }
        $ResponseBody = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $_.ErrorDetails.Message
        } else {
            $_.Exception.Message
        }
        return [pscustomobject]@{
            Status = $Status
            Body = $ResponseBody
        }
    }
}

function Get-ExistingEnvironment {
    $Values = @{}
    if (-not (Test-Path $EnvPath)) {
        return $Values
    }

    foreach ($Line in Get-Content $EnvPath) {
        $Trimmed = $Line.Trim()
        if (-not $Trimmed -or $Trimmed.StartsWith('#') -or -not $Trimmed.Contains('=')) {
            continue
        }
        $Key, $Value = $Trimmed.Split('=', 2)
        $Values[$Key.Trim()] = $Value.Trim().Trim('"').Trim("'")
    }
    return $Values
}

function Find-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Executable = 'py'; Prefix = @('-3') }
    }
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Executable = 'python3'; Prefix = @() }
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return [pscustomobject]@{ Executable = 'python'; Prefix = @() }
    }
    throw 'Python 3.10 or newer is required.'
}

function Invoke-Python {
    param(
        [pscustomobject]$Python,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $AllArguments = @($Python.Prefix) + $Arguments
    & $Python.Executable @AllArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed: $($Arguments -join ' ')"
    }
}

Write-Step '0/7 Preflight'
Get-Command az -ErrorAction Stop | Out-Null
Invoke-Az @('account', 'show', '--output', 'none') | Out-Null
Invoke-Az @('extension', 'show', '--name', 'databricks', '--output', 'none') | Out-Null
$Python = Find-Python
Invoke-Python $Python @(
    '-c',
    'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'
)
if ($ConfigureClaudeCode -and -not (Test-Path $ConfiguratorPath)) {
    throw "Claude Code configurator not found: $ConfiguratorPath"
}
if ($RunAgent -and -not (Test-Path $AgentPython)) {
    throw 'RUN_AGENT=1 requires .venv. Follow docs/agent-framework.md.'
}
if ($RunAgent) {
    & $AgentPython -c 'import agent_framework.openai, dotenv, httpx, openai'
    if ($LASTEXITCODE -ne 0) {
        throw 'RUN_AGENT=1 requires dependencies from requirements.txt.'
    }
}
$SubscriptionName = (Invoke-Az @('account', 'show', '--query', 'name', '--output', 'tsv')).Trim()
Write-Success "az logged in - subscription: $SubscriptionName"

Write-Step "1/7 Resource group '$ResourceGroup' ($Location)"
if (Test-AzResource @('group', 'show', '--name', $ResourceGroup)) {
    Write-Success 'resource group already exists'
} else {
    Invoke-Az @('group', 'create', '--name', $ResourceGroup, '--location', $Location, '--output', 'none') | Out-Null
    Write-Success 'resource group created'
}

Write-Step "2/7 Databricks workspace '$Workspace'"
if (Test-AzResource @('databricks', 'workspace', 'show', '--resource-group', $ResourceGroup, '--name', $Workspace)) {
    Write-Success 'workspace already exists'
} else {
    Write-Warning 'creating workspace (this can take several minutes)...'
    Invoke-Az @(
        'databricks', 'workspace', 'create',
        '--resource-group', $ResourceGroup,
        '--name', $Workspace,
        '--location', $Location,
        '--sku', $Sku,
        '--output', 'none'
    ) | Out-Null
    Write-Success 'workspace created'
}
$WorkspaceHost = (Invoke-Az @(
    'databricks', 'workspace', 'show',
    '--resource-group', $ResourceGroup,
    '--name', $Workspace,
    '--query', 'workspaceUrl',
    '--output', 'tsv'
)).Trim()
$WorkspaceUrl = "https://$WorkspaceHost"
Write-Success "workspace URL: $WorkspaceUrl"

$ExistingEnvironment = Get-ExistingEnvironment
$ExistingHost = $ExistingEnvironment['DATABRICKS_HOST']
$ExistingToken = $ExistingEnvironment['DATABRICKS_TOKEN']
if (
    -not $EndpointExplicit -and
    $ExistingHost -and
    $ExistingHost.TrimEnd('/') -eq $WorkspaceUrl -and
    $ExistingEnvironment['DATABRICKS_SERVING_ENDPOINT']
) {
    $Endpoint = $ExistingEnvironment['DATABRICKS_SERVING_ENDPOINT']
}

Write-Step '3/7 Databricks PAT + .env'
$Token = $null
$TokenAction = 'created'
if (
    -not $RotatePat -and
    $ExistingHost -and
    $ExistingToken -and
    $ExistingHost.TrimEnd('/') -eq $WorkspaceUrl
) {
    $Validation = Invoke-JsonRequest `
        -Method GET `
        -Uri "$WorkspaceUrl/api/2.0/serving-endpoints" `
        -Token $ExistingToken
    if ($Validation.Status -eq 200) {
        $Token = $ExistingToken
        $TokenAction = 'reused'
        Write-Success 'reusing the valid PAT already stored in .env'
    } elseif ($Validation.Status -eq 401) {
        Write-Warning 'the PAT in .env is invalid or expired; creating a replacement'
    } else {
        throw "Could not verify the PAT in .env (HTTP $($Validation.Status))."
    }
}

if (-not $Token) {
    $AadToken = (Invoke-Az @(
        'account', 'get-access-token',
        '--resource', $DatabricksAadResource,
        '--query', 'accessToken',
        '--output', 'tsv'
    )).Trim()
    $PatBody = @{
        comment = 'claude-workspace-setup'
        lifetime_seconds = $PatLifetimeSeconds
    } | ConvertTo-Json -Compress
    $PatResponse = Invoke-JsonRequest `
        -Method POST `
        -Uri "$WorkspaceUrl/api/2.0/token/create" `
        -Token $AadToken `
        -Body $PatBody
    if ($PatResponse.Status -lt 200 -or $PatResponse.Status -ge 300) {
        throw "Failed to create a PAT (HTTP $($PatResponse.Status)): $($PatResponse.Body)"
    }
    $Token = ($PatResponse.Body | ConvertFrom-Json).token_value
    if (-not $Token) {
        throw 'Failed to create a PAT. The response did not include token_value.'
    }
    Write-Success "created a new PAT (ROTATE_PAT=$([int]$RotatePat))"
}

$EnvContent = @"
# Azure Databricks workspace URL
DATABRICKS_HOST=$WorkspaceUrl

# Default Databricks-hosted Claude model
DATABRICKS_SERVING_ENDPOINT=$Endpoint

# Fast local validation: Databricks Personal Access Token (PAT)
DATABRICKS_TOKEN=$Token
"@
[IO.File]::WriteAllText(
    $EnvPath,
    $EnvContent,
    [Text.UTF8Encoding]::new($false)
)
Protect-File $EnvPath
Write-Success ".env written (HOST + $Endpoint + $TokenAction PAT). PAT length: $($Token.Length)"
Write-Warning 'PAT is the easiest local setup. Consider OAuth U2M or M2M for long-lived security.'

Write-Step '4/7 Verify serving endpoints'
$EndpointResponse = Invoke-JsonRequest `
    -Method GET `
    -Uri "$WorkspaceUrl/api/2.0/serving-endpoints" `
    -Token $Token
if ($EndpointResponse.Status -eq 200) {
    $EndpointStates = @{}
    $EndpointPayload = $EndpointResponse.Body | ConvertFrom-Json
    $EndpointsProperty = $EndpointPayload.PSObject.Properties['endpoints']
    $ServingEndpoints = if ($EndpointsProperty) { @($EndpointsProperty.Value) } else { @() }
    foreach ($ServingEndpoint in $ServingEndpoints) {
        $NameProperty = $ServingEndpoint.PSObject.Properties['name']
        if (-not $NameProperty) {
            continue
        }
        $Ready = 'UNKNOWN'
        $StateProperty = $ServingEndpoint.PSObject.Properties['state']
        if ($StateProperty -and $StateProperty.Value) {
            $ReadyProperty = $StateProperty.Value.PSObject.Properties['ready']
            if ($ReadyProperty -and $ReadyProperty.Value) {
                $Ready = $ReadyProperty.Value
            }
        }
        $EndpointStates[$NameProperty.Value] = $Ready
    }
    foreach ($Name in @($Endpoint, $FallbackEndpoint)) {
        $State = if ($EndpointStates.ContainsKey($Name)) { $EndpointStates[$Name] } else { 'NOT FOUND' }
        Write-Host "  ${Name}: $State"
    }
} else {
    throw "Could not list serving endpoints (HTTP $($EndpointResponse.Status))."
}

Write-Step '5/7 Model connection test'
$ChatBody = @{
    model = $Endpoint
    messages = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
    max_tokens = 10
} | ConvertTo-Json -Depth 4 -Compress
$ChatResponse = Invoke-JsonRequest `
    -Method POST `
    -Uri "$WorkspaceUrl/serving-endpoints/chat/completions" `
    -Token $Token `
    -Body $ChatBody
$WorkingEndpoint = $null
$ClaudeCodeReady = $false
if ($ChatResponse.Status -eq 200) {
    $Reply = (($ChatResponse.Body | ConvertFrom-Json).choices[0].message.content)
    Write-Success "OpenAI-compatible route for '$Endpoint' responded: $Reply"
    $WorkingEndpoint = $Endpoint

    $AnthropicBody = @{
        model = $Endpoint
        messages = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
        max_tokens = 10
    } | ConvertTo-Json -Depth 4 -Compress
    $AnthropicResponse = Invoke-JsonRequest `
        -Method POST `
        -Uri "$WorkspaceUrl/serving-endpoints/anthropic/v1/messages" `
        -Token $Token `
        -Body $AnthropicBody `
        -AdditionalHeaders @{ 'anthropic-version' = '2023-06-01' }
    if (
        $AnthropicResponse.Status -eq 200 -and
        ($AnthropicResponse.Body | ConvertFrom-Json).type -eq 'message'
    ) {
        $ClaudeCodeReady = $true
        Write-Success "native Anthropic route responded with type='message'"
    } else {
        Write-Warning "native Anthropic route failed for '$Endpoint' (HTTP $($AnthropicResponse.Status))"
    }
} else {
    Write-Warning "target '$Endpoint' failed (HTTP $($ChatResponse.Status)): $($ChatResponse.Body)"
    $FallbackBody = @{
        model = $FallbackEndpoint
        messages = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
        max_tokens = 10
    } | ConvertTo-Json -Depth 4 -Compress
    $FallbackResponse = Invoke-JsonRequest `
        -Method POST `
        -Uri "$WorkspaceUrl/serving-endpoints/chat/completions" `
        -Token $Token `
        -Body $FallbackBody
    if ($FallbackResponse.Status -eq 200) {
        $WorkingEndpoint = $FallbackEndpoint
        Write-Success "fallback '$FallbackEndpoint' responded (auth + path + PAT verified)"
    } else {
        Write-Warning "fallback '$FallbackEndpoint' also failed (HTTP $($FallbackResponse.Status))"
    }
}

Write-Step '6/7 Configure Claude Code'
$ClaudeSettingsConfigured = $false
$ClaudeSettingsFailed = $false
if ($ClaudeCodeReady -and $ConfigureClaudeCode) {
    $PreviousHost = $env:DATABRICKS_HOST
    $PreviousToken = $env:DATABRICKS_TOKEN
    try {
        $env:DATABRICKS_HOST = $WorkspaceUrl
        $env:DATABRICKS_TOKEN = $Token
        $ConfiguratorArguments = @(
            $ConfiguratorPath,
            '--scope', $ClaudeCodeScope
        )
        if ($ClaudeCodeScope -eq 'project') {
            $ConfiguratorArguments += @('--project-dir', $RepoRoot)
        }
        Invoke-Python $Python @ConfiguratorArguments
        $ClaudeSettingsConfigured = $true
        Write-Success "Claude Code multi-model settings configured (scope: $ClaudeCodeScope)"
    } catch {
        $ClaudeSettingsFailed = $true
        Write-Warning "workspace and model are ready, but Claude Code settings configuration failed: $($_.Exception.Message)"
    } finally {
        $env:DATABRICKS_HOST = $PreviousHost
        $env:DATABRICKS_TOKEN = $PreviousToken
    }
} elseif (-not $ConfigureClaudeCode) {
    Write-Success 'skipped (CONFIGURE_CLAUDE_CODE=0)'
} else {
    Write-Warning 'skipped because the native Anthropic route is not ready'
}

Write-Step '7/7 Optional Agent Framework sample'
if ($RunAgent -and $WorkingEndpoint) {
    $PreviousEndpoint = $env:DATABRICKS_SERVING_ENDPOINT
    try {
        $env:DATABRICKS_SERVING_ENDPOINT = $WorkingEndpoint
        Push-Location $RepoRoot
        try {
            '' | & $AgentPython $AgentSample
            if ($LASTEXITCODE -ne 0) {
                throw 'Agent Framework sample failed.'
            }
        } finally {
            Pop-Location
        }
    } finally {
        $env:DATABRICKS_SERVING_ENDPOINT = $PreviousEndpoint
    }
} elseif ($RunAgent) {
    Write-Warning 'skipped because no working endpoint was found'
} else {
    Write-Success 'skipped (set RUN_AGENT=1 to run the optional sample)'
}

Write-Host
Write-Success "Done. Workspace: $WorkspaceUrl"
if ($WorkingEndpoint -eq $Endpoint) {
    Write-Success "OpenAI-compatible route for '$Endpoint' is live; .env is ready."
    if ($ClaudeCodeReady -and $ClaudeSettingsConfigured) {
        Write-Success "Claude Code is ready. Run 'claude' and select a Databricks model with /model."
    } elseif (-not $ClaudeCodeReady) {
        Write-Warning 'Native Anthropic route is not ready; Claude Code is not ready for this model.'
    }
} else {
    Write-Warning "Claude '$Endpoint' is unavailable; review region, cross-Geo, permissions, and capacity."
}

if ($ClaudeSettingsFailed) {
    throw 'Fix the existing Claude Code settings and rerun scripts\configure_claude_code.py.'
}
