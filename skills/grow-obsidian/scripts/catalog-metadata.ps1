param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-JsonFile $ConfigPath
if (-not $config) {
    throw "Config not found or empty: $ConfigPath"
}
$vaultRoot = Normalize-Path ([string]$config.vaultRoot)
$dataRoot = Normalize-Path ([string]$config.controllerDataRoot)
$results = [System.Collections.Generic.List[object]]::new()

$metadataSources = @()
if (Test-HasProperty $config 'metadataOnlySources') {
    $metadataSources = @($config.metadataOnlySources)
}

foreach ($source in $metadataSources) {
    if ($source.readFileContents -ne $false) {
        throw "Metadata source is not protected by readFileContents=false: $($source.id)"
    }
    $root = Normalize-Path ([string]$source.path)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'NOT_FOUND'; path = $root })
        continue
    }

    $extensions = if (Test-HasProperty $source 'allowedExtensions') {
        @($source.allowedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    } else {
        @('.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.wps', '.et', '.dps')
    }
    $strip = if (Test-HasProperty $source 'stripPrefixSegments') { [int]$source.stripPrefixSegments } else { 0 }
    $groupDepth = if (Test-HasProperty $source 'groupDepth') { [int]$source.groupDepth } else { 1 }

    $includePrefixes = @(if (Test-HasProperty $source 'includeRelativePrefixes') {
        $source.includeRelativePrefixes | ForEach-Object { ([string]$_).TrimStart('\', '/') }
    } else {
        @() | Write-Output
    })
    $ignoredDirectories = @(if (Test-HasProperty $source 'ignoredDirectories') {
        $source.ignoredDirectories | ForEach-Object { ([string]$_).ToLowerInvariant() }
    } else {
        @('cache', 'cachedata', 'temp') | Write-Output
    })

    $inaccessible = 0
    $candidates = Get-CandidateFiles -Root $root -IgnoredDirectoryNames $ignoredDirectories -InaccessibleCount ([ref]$inaccessible)
    $files = @($candidates | Where-Object {
        $candidateRelative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        $matchesPrefix = $includePrefixes.Count -eq 0 -or @($includePrefixes | Where-Object {
            $candidateRelative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0

        $_.Length -gt 0 -and
        -not $_.Name.StartsWith('~$') -and
        $matchesPrefix -and
        $extensions -contains $_.Extension.ToLowerInvariant()
    } | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        $segments = @($relative -split '[\\/]')
        $directorySegments = if ($segments.Count -gt 1) { @($segments[0..($segments.Count - 2)]) } else { @() }
        if ($strip -gt 0 -and $directorySegments.Count -gt $strip) {
            $directorySegments = @($directorySegments[$strip..($directorySegments.Count - 1)])
        } elseif ($strip -ge $directorySegments.Count) {
            $directorySegments = @()
        }
        $take = [Math]::Min([Math]::Max(1, $groupDepth), $directorySegments.Count)
        $group = if ($take -gt 0) { @($directorySegments[0..($take - 1)]) -join ' / ' } else { '[根目录]' }
        [PSCustomObject]@{
            name = $_.Name
            fullPath = $_.FullName
            group = $group
            modified = $_.LastWriteTime
            sizeBytes = $_.Length
        }
    } | Sort-Object @{Expression = 'modified'; Descending = $true}, @{Expression = 'fullPath'; Descending = $false})

    $lines = [System.Collections.Generic.List[string]]::new()
    $title = if (Test-HasProperty $source 'title') {
        [string]$source.title
    } elseif (Test-HasProperty $source 'label') {
        [string]$source.label + '索引'
    } else {
        '文件索引'
    }
    $lines.Add('# ' + $title)
    $lines.Add('')
    $lines.Add('> 本页由 Obsidian AutoGrow 根据文件元数据生成，不读取或分析文档正文。')
    $lines.Add('')
    $lines.Add("- 文件数量：$($files.Count)")
    $latest = $files | Select-Object -First 1
    $lines.Add("- 最近修改：" + $(if ($latest) { $latest.modified.ToString('yyyy-MM-dd HH:mm') } else { '无文件' }))
    $lines.Add('')

    foreach ($group in @($files | Group-Object group | Sort-Object Name)) {
        $lines.Add('## ' + $group.Name)
        $lines.Add('')
        foreach ($file in @($group.Group | Sort-Object modified -Descending)) {
            $sizeKb = [Math]::Round($file.sizeBytes / 1KB, 1)
            $uri = ([Uri]$file.fullPath).AbsoluteUri
            $lines.Add("- $($file.modified.ToString('yyyy-MM-dd')) · [$($file.name)]($uri) · $sizeKb KB")
        }
        $lines.Add('')
    }

    if ([IO.Path]::IsPathRooted([string]$source.destination)) {
        throw "Metadata destination must be relative to the vault: $($source.destination)"
    }
    $destination = Normalize-Path (Join-Path $vaultRoot ([string]$source.destination))
    if (-not (Test-PathWithin $destination $vaultRoot)) {
        throw "Metadata destination is outside vault: $destination"
    }
    $content = ($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    $existing = if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Get-Content -LiteralPath $destination -Raw -Encoding UTF8
    } else {
        ''
    }

    if ($existing -eq $content) {
        $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'UNCHANGED'; fileCount = $files.Count; destination = $destination })
        continue
    }

    # This tool regenerates the whole index file, so it must only ever
    # overwrite files it generated itself. A file without the generator
    # sentinel is human-authored; leave it untouched and report.
    if ($existing -and -not ($existing.Contains('本页由 Obsidian AutoGrow') -or $existing.Contains('本页由 Grow Obsidian'))) {
        $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'SKIPPED_HUMAN_FILE'; fileCount = $files.Count; destination = $destination })
        continue
    }

    if ($existing) {
        $relativeDestination = $destination.Substring($vaultRoot.Length).TrimStart('\', '/')
        $backup = Join-Path (Join-Path $dataRoot 'backups\metadata') ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
        $backup = Join-Path $backup $relativeDestination
        $backupParent = Split-Path -Parent $backup
        if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        }
        [IO.File]::Copy($destination, $backup, $false)
    }

    Write-TextAtomic -Path $destination -Content $content
    $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'UPDATED'; fileCount = $files.Count; destination = $destination; inaccessibleDirectories = $inaccessible })
}

[ordered]@{
    status = 'OK'
    contentRead = $false
    sources = @($results)
} | ConvertTo-Json -Depth 6
