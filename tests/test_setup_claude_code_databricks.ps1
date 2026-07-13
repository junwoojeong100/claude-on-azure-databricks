$ErrorActionPreference = 'Stop'

$ScriptPath = Resolve-Path (
    Join-Path $PSScriptRoot '..\scripts\setup_claude_code_databricks.ps1'
)
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count) {
    throw "PowerShell setup script has $($ParseErrors.Count) parse error(s)."
}

foreach ($FunctionName in 'Test-JsonObject', 'Test-AnthropicMessageResponse') {
    $FunctionAst = $Ast.Find(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $Node.Name -eq $FunctionName
        },
        $true
    ) | Select-Object -First 1
    if (-not $FunctionAst) {
        throw "Could not find function '$FunctionName'."
    }
    . ([scriptblock]::Create($FunctionAst.Extent.Text))
}

$Message = [pscustomobject]@{ type = 'message' }
if (-not (Test-AnthropicMessageResponse $Message)) {
    throw 'A top-level Anthropic message object must be accepted.'
}

$MessageArray = @(
    [pscustomobject]@{ type = 'error' },
    [pscustomobject]@{ type = 'message' }
)
if (Test-AnthropicMessageResponse $MessageArray) {
    throw 'A top-level array must not be accepted as an Anthropic message.'
}

foreach ($InvalidResponse in @(
    [pscustomobject]@{ type = 'error' },
    [pscustomobject]@{ type = @('message') },
    [pscustomobject]@{ content = @() },
    @{ type = 'message' },
    $null
)) {
    if (Test-AnthropicMessageResponse $InvalidResponse) {
        throw "Invalid response was accepted: $($InvalidResponse | Out-String)"
    }
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$MarkdownFiles = @(
    Join-Path $RepoRoot 'README.md'
    Get-ChildItem (Join-Path $RepoRoot 'docs') -Filter '*.md'
)
$PowerShellFence = [regex]'(?ms)^```(?:powershell|pwsh)\s*\r?\n(.*?)^```\s*$'
$PowerShellFenceCount = 0
foreach ($MarkdownFile in $MarkdownFiles) {
    $MarkdownText = Get-Content $MarkdownFile -Raw
    foreach ($Match in $PowerShellFence.Matches($MarkdownText)) {
        $PowerShellFenceCount++
        $FenceTokens = $null
        $FenceErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $Match.Groups[1].Value,
            [ref]$FenceTokens,
            [ref]$FenceErrors
        ) | Out-Null
        if ($FenceErrors.Count) {
            $LineNumber = 1 + [regex]::Matches(
                $MarkdownText.Substring(0, $Match.Index),
                "`n"
            ).Count
            $Details = ($FenceErrors | ForEach-Object { $_.Message }) -join '; '
            $RelativePath = Resolve-Path -Relative $MarkdownFile
            throw "${RelativePath}:$LineNumber PowerShell fence parse error(s): $Details"
        }
    }
}
if (-not $PowerShellFenceCount) {
    throw 'No PowerShell documentation fences were found.'
}
