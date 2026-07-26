param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$RelativeNotePath,

    [Parameter(Mandatory = $true)]
    [string]$GeneratedBlockPath,

    [string]$NewNoteTemplatePath = '',

    [string]$ExpectedCurrentHash = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

. (Join-Path $PSScriptRoot 'common.ps1')

function Get-FileHashValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$config = Read-JsonFile $ConfigPath
if (-not $config) {
    throw "Config not found or empty: $ConfigPath"
}
$vaultRoot = Normalize-Path ([string]$config.vaultRoot)
$dataRoot = Normalize-Path ([string]$config.controllerDataRoot)
$notePath = Normalize-Path (Join-Path $vaultRoot $RelativeNotePath)

if (-not (Test-PathWithin $notePath $vaultRoot)) {
    throw "Refusing to write outside vault: $notePath"
}
if ([IO.Path]::GetExtension($notePath).ToLowerInvariant() -ne '.md') {
    throw 'Target note must be a Markdown file.'
}
if (-not (Test-Path -LiteralPath $GeneratedBlockPath -PathType Leaf)) {
    throw "Generated block not found: $GeneratedBlockPath"
}

$generated = (Get-Content -LiteralPath $GeneratedBlockPath -Raw -Encoding UTF8).Trim()
$startMarker = '<!-- AI-MAINTAINED:START -->'
$endMarker = '<!-- AI-MAINTAINED:END -->'
if ($generated.Contains($startMarker) -or $generated.Contains($endMarker)) {
    throw 'Generated block must not contain maintenance markers.'
}

$existing = ''
if (Test-Path -LiteralPath $notePath -PathType Leaf) {
    $actualHash = Get-FileHashValue $notePath
    if ($ExpectedCurrentHash -and $actualHash -ne $ExpectedCurrentHash.ToLowerInvariant()) {
        throw "Conflict detected. Expected $ExpectedCurrentHash but found $actualHash"
    }
    $existing = Get-Content -LiteralPath $notePath -Raw -Encoding UTF8
}

$replacement = $startMarker + [Environment]::NewLine + $generated + [Environment]::NewLine + $endMarker
$startIndex = $existing.IndexOf($startMarker, [StringComparison]::Ordinal)
$endIndex = $existing.IndexOf($endMarker, [StringComparison]::Ordinal)

if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
    $endAfter = $endIndex + $endMarker.Length
    $newContent = $existing.Substring(0, $startIndex) + $replacement + $existing.Substring($endAfter)
} elseif ($startIndex -ge 0 -or $endIndex -ge 0) {
    throw 'Maintenance markers are incomplete; refusing to modify the note.'
} elseif ($existing) {
    $newContent = $existing.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $replacement + [Environment]::NewLine
} elseif ($NewNoteTemplatePath) {
    if (-not (Test-Path -LiteralPath $NewNoteTemplatePath -PathType Leaf)) {
        throw "New note template not found: $NewNoteTemplatePath"
    }
    $template = Get-Content -LiteralPath $NewNoteTemplatePath -Raw -Encoding UTF8
    if (-not $template.Contains('{{AI_BLOCK}}')) {
        throw 'New note template must contain {{AI_BLOCK}}.'
    }
    $newContent = $template.Replace('{{AI_BLOCK}}', $replacement).TrimEnd() + [Environment]::NewLine
} else {
    $newContent = $replacement + [Environment]::NewLine
}

$backupPath = $null
if (Test-Path -LiteralPath $notePath -PathType Leaf) {
    $relative = $notePath.Substring($vaultRoot.Length).TrimStart('\', '/')
    $backupPath = Join-Path (Join-Path $dataRoot 'backups') ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    $backupPath = Join-Path $backupPath $relative
    $backupParent = Split-Path -Parent $backupPath
    if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    }
    [IO.File]::Copy($notePath, $backupPath, $false)
}

Write-TextAtomic -Path $notePath -Content $newContent

[ordered]@{
    status = 'OK'
    notePath = $notePath
    noteHash = Get-FileHashValue $notePath
    backupPath = $backupPath
} | ConvertTo-Json -Depth 4
