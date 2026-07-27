$ErrorActionPreference = 'Stop'

$ProfileName = if ($env:DATABRICKS_CONFIG_PROFILE) {
    $env:DATABRICKS_CONFIG_PROFILE
} else {
    'claude-code'
}

Get-Command databricks -ErrorAction Stop | Out-Null

$TokenJson = & databricks auth token --profile $ProfileName --output json
if ($LASTEXITCODE -ne 0) {
    throw "Databricks CLI failed to get an OAuth token for profile '$ProfileName'."
}

$TokenResponse = $TokenJson | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($TokenResponse.access_token)) {
    throw 'Databricks CLI did not return access_token.'
}

$TokenResponse.access_token
