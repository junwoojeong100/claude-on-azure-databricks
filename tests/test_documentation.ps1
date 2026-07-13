$ErrorActionPreference = 'Stop'

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
            throw "${RelativePath}:$LineNumber PowerShell fence error(s): $Details"
        }
    }
}

if (-not $PowerShellFenceCount) {
    throw 'No PowerShell documentation fences were found.'
}
