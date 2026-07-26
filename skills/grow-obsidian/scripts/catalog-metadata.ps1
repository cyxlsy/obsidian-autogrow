param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Normalize-Path {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathWithin {
    param([string]$Candidate, [string]$Parent)
    $candidatePath = Normalize-Path $Candidate
    $parentPath = Normalize-Path $Parent
    return $candidatePath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$vaultRoot = Normalize-Path ([string]$config.vaultRoot)
$dataRoot = Normalize-Path ([string]$config.controllerDataRoot)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($source in @($config.metadataOnlySources)) {
    if ($source.readFileContents -ne $false) {
        throw "Metadata source is not protected by readFileContents=false: $($source.id)"
    }
    $root = Normalize-Path ([string]$source.path)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'NOT_FOUND'; path = $root })
        continue
    }

    $extensions = if ($source.PSObject.Properties.Name -contains 'allowedExtensions') {
        @($source.allowedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    } else {
        @('.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf', '.wps', '.et', '.dps')
    }
    $strip = if ($source.PSObject.Properties.Name -contains 'stripPrefixSegments') { [int]$source.stripPrefixSegments } else { 0 }
    $groupDepth = if ($source.PSObject.Properties.Name -contains 'groupDepth') { [int]$source.groupDepth } else { 1 }

    $includePrefixes = @(if ($source.PSObject.Properties.Name -contains 'includeRelativePrefixes') {
        $source.includeRelativePrefixes | ForEach-Object { ([string]$_).TrimStart('\', '/') }
    } else {
        @() | Write-Output
    })
    $ignoredDirectories = @(if ($source.PSObject.Properties.Name -contains 'ignoredDirectories') {
        $source.ignoredDirectories | ForEach-Object { ([string]$_).ToLowerInvariant() }
    } else {
        @('cache', 'cachedata', 'temp') | Write-Output
    })

    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $candidateRelative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        $candidateSegments = @($candidateRelative -split '[\\/]')
        $candidateParents = if ($candidateSegments.Count -gt 1) { @($candidateSegments[0..($candidateSegments.Count - 2)]) } else { @() }
        $hasIgnoredDirectory = @($candidateParents | Where-Object {
            $_.StartsWith('.') -or $ignoredDirectories -contains $_.ToLowerInvariant()
        }).Count -gt 0
        $matchesPrefix = $includePrefixes.Count -eq 0 -or @($includePrefixes | Where-Object {
            $candidateRelative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0

        $_.Length -gt 0 -and
        -not $_.Name.StartsWith('~$') -and
        -not $hasIgnoredDirectory -and
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
    $title = if ($source.PSObject.Properties.Name -contains 'title') { [string]$source.title } else { [string]$source.label + '索引' }
    $lines.Add('# ' + $title)
    $lines.Add('')
    $lines.Add('> 本页由 Grow Obsidian 根据文件元数据生成，不读取或分析文档正文。')
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

    $destination = Normalize-Path (Join-Path $vaultRoot ([string]$source.destination))
    if (-not (Test-PathWithin $destination $vaultRoot)) {
        throw "Metadata destination is outside vault: $destination"
    }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
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

    $temporary = Join-Path $parent ('.grow-obsidian-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $replaceBackup = $destination + '.replace-backup'
        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
            [IO.File]::Delete($replaceBackup)
        }
        [IO.File]::Replace($temporary, $destination, $replaceBackup)
        [IO.File]::Delete($replaceBackup)
    } else {
        [IO.File]::Move($temporary, $destination)
    }
    $results.Add([PSCustomObject]@{ id = [string]$source.id; status = 'UPDATED'; fileCount = $files.Count; destination = $destination })
}

[ordered]@{
    status = 'OK'
    contentRead = $false
    sources = @($results)
} | ConvertTo-Json -Depth 6
