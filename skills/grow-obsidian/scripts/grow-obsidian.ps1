param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Doctor', 'Init', 'Scan', 'Next', 'Approve', 'Ack', 'Status', 'Discover')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string[]]$ItemIds = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonAtomic {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporary = Join-Path $parent ('.tmp-' + [Guid]::NewGuid().ToString('N') + '.json')
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $replaceBackup = $Path + '.replace-backup'
        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
            [IO.File]::Delete($replaceBackup)
        }
        [IO.File]::Replace($temporary, $Path, $replaceBackup)
        [IO.File]::Delete($replaceBackup)
    } else {
        [IO.File]::Move($temporary, $Path)
    }
}

function Normalize-Path {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathWithin {
    param(
        [string]$Candidate,
        [string]$Parent
    )
    $candidatePath = Normalize-Path $Candidate
    $parentPath = Normalize-Path $Parent
    return $candidatePath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-HashString {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config not found: $ConfigPath"
    }
    $config = Read-JsonFile $ConfigPath
    if (-not $config) {
        throw "Config is empty: $ConfigPath"
    }
    return $config
}

function Get-DataPaths {
    param([object]$Config)
    $root = Normalize-Path ([string]$Config.controllerDataRoot)
    return [ordered]@{
        root = $root
        state = Join-Path $root 'state.local.json'
        queue = Join-Path $root 'queue.local.json'
        backups = Join-Path $root 'backups'
        reports = Join-Path $root 'reports'
    }
}

function New-EmptyState {
    return [ordered]@{
        schemaVersion = 1
        sources = @()
    }
}

function New-EmptyQueue {
    return [ordered]@{
        schemaVersion = 1
        items = @()
    }
}

function Get-State {
    param([hashtable]$Paths)
    $saved = Read-JsonFile $Paths.state
    if (-not $saved) {
        return New-EmptyState
    }
    return [ordered]@{
        schemaVersion = 1
        sources = @($saved.sources)
    }
}

function Get-Queue {
    param([hashtable]$Paths)
    $saved = Read-JsonFile $Paths.queue
    if (-not $saved) {
        return New-EmptyQueue
    }
    return [ordered]@{
        schemaVersion = 1
        items = @($saved.items)
    }
}

function Invoke-Doctor {
    param([object]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ([int]$Config.schemaVersion -ne 1) {
        $errors.Add('Unsupported schemaVersion. Expected 1.')
    }
    if (-not $Config.vaultRoot) {
        $errors.Add('vaultRoot is required.')
    } elseif (-not (Test-Path -LiteralPath ([string]$Config.vaultRoot) -PathType Container)) {
        $errors.Add("Vault not found: $($Config.vaultRoot)")
    }
    if (-not $Config.controllerDataRoot) {
        $errors.Add('controllerDataRoot is required.')
    }

    $sources = @($Config.semanticSources)
    if ($sources.Count -eq 0) {
        $errors.Add('At least one semanticSources entry is required.')
    }

    $ids = @{}
    foreach ($source in $sources) {
        $id = [string]$source.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add('Every semantic source requires an id.')
            continue
        }
        if ($ids.ContainsKey($id.ToLowerInvariant())) {
            $errors.Add("Duplicate source id: $id")
        } else {
            $ids[$id.ToLowerInvariant()] = $true
        }
        if (-not (Test-Path -LiteralPath ([string]$source.path) -PathType Container)) {
            $errors.Add("Source not found: $($source.path)")
        }
    }

    if ($Config.vaultRoot -and $Config.controllerDataRoot) {
        $vault = Normalize-Path ([string]$Config.vaultRoot)
        $dataRoot = Normalize-Path ([string]$Config.controllerDataRoot)
        if ((Test-PathWithin $dataRoot $vault) -or (Test-PathWithin $vault $dataRoot)) {
            $errors.Add('controllerDataRoot and vaultRoot must not contain each other.')
        }
    }

    for ($i = 0; $i -lt $sources.Count; $i++) {
        for ($j = $i + 1; $j -lt $sources.Count; $j++) {
            $a = [string]$sources[$i].path
            $b = [string]$sources[$j].path
            if ((Test-PathWithin $a $b) -or (Test-PathWithin $b $a)) {
                $errors.Add("Semantic source roots overlap: $a | $b")
            }
        }
        if ($Config.vaultRoot) {
            $sourcePath = [string]$sources[$i].path
            $vaultPath = [string]$Config.vaultRoot
            if ((Test-PathWithin $sourcePath $vaultPath) -or (Test-PathWithin $vaultPath $sourcePath)) {
                $errors.Add("Semantic source and vault overlap: $sourcePath")
            }
        }
    }

    if ([int]$Config.scanPolicy.maxFilesPerBatch -lt 1) {
        $errors.Add('scanPolicy.maxFilesPerBatch must be greater than zero.')
    }
    if ([int]$Config.scanPolicy.maxSemanticFileBytes -lt 1024) {
        $warnings.Add('maxSemanticFileBytes is unusually small.')
    }
    if ($Config.features.creatorInsights.enabled -eq $true -and
        [string]$Config.features.creatorInsights.input -ne 'distilled-notes-only') {
        $errors.Add('Creator insights must use distilled-notes-only input.')
    }

    return [ordered]@{
        status = if ($errors.Count -eq 0) { 'OK' } else { 'ERROR' }
        errors = @($errors)
        warnings = @($warnings)
        semanticSourceCount = $sources.Count
        vaultRoot = [string]$Config.vaultRoot
        controllerDataRoot = [string]$Config.controllerDataRoot
    }
}

function Assert-Doctor {
    param([object]$Config)
    $result = Invoke-Doctor $Config
    if ($result.status -ne 'OK') {
        throw ('Doctor failed: ' + ($result.errors -join '; '))
    }
}

function Test-ExcludedFile {
    param(
        [IO.FileInfo]$File,
        [string]$SourceRoot,
        [object]$Config
    )

    $relative = $File.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
    $segments = @($relative -split '[\\/]')
    $parentSegments = if ($segments.Count -gt 1) { @($segments[0..($segments.Count - 2)]) } else { @() }
    $ignoredDirs = @($Config.privacy.ignoredDirectories | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $ignoredFiles = @($Config.privacy.ignoredFileNames | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $ignoredFragments = @($Config.privacy.ignoredNameFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $allowed = @($Config.scanPolicy.allowedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $lowerName = $File.Name.ToLowerInvariant()
    $extension = $File.Extension.ToLowerInvariant()

    if (@($parentSegments | Where-Object {
        $part = $_.ToLowerInvariant()
        $part.StartsWith('.') -or ($ignoredDirs -contains $part)
    }).Count -gt 0) {
        return $true
    }
    if ($lowerName.StartsWith('~$') -or $ignoredFiles -contains $lowerName) {
        return $true
    }
    if (@($ignoredFragments | Where-Object { $lowerName.Contains($_) }).Count -gt 0) {
        return $true
    }
    if (-not ($allowed -contains $extension)) {
        return $true
    }
    foreach ($excluded in @($Config.privacy.excludedPaths)) {
        if (Test-PathWithin $File.FullName ([string]$excluded)) {
            return $true
        }
    }
    return $false
}

function Get-Priority {
    param(
        [IO.FileInfo]$File,
        [object]$Config
    )
    $score = 0
    $extension = $File.Extension.ToLowerInvariant()
    $highExtensions = @($Config.scanPolicy.highValueExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($highExtensions -contains $extension) {
        $score += 50
    }
    $lowerName = $File.Name.ToLowerInvariant()
    foreach ($fragment in @($Config.scanPolicy.highValueNameFragments)) {
        if ($lowerName.Contains(([string]$fragment).ToLowerInvariant())) {
            $score += 50
            break
        }
    }
    return $score
}

function Test-SensitivePath {
    param(
        [string]$RelativePath,
        [object]$Config
    )
    if (-not ($Config.privacy.PSObject.Properties.Name -contains 'sensitiveNameFragments')) {
        return $false
    }
    $lowerPath = $RelativePath.ToLowerInvariant()
    foreach ($fragment in @($Config.privacy.sensitiveNameFragments)) {
        if ($lowerPath.Contains(([string]$fragment).ToLowerInvariant())) {
            return $true
        }
    }
    return $false
}

function Get-TopicKey {
    param(
        [string]$SourceId,
        [string]$RelativePath,
        [string]$Mode = 'top-level',
        [int]$Depth = 1
    )
    if ($Mode -eq 'source') {
        return $SourceId + '::[source]'
    }
    $segments = @($RelativePath -split '[\\/]')
    if ($segments.Count -gt 1) {
        $directoryCount = $segments.Count - 1
        $take = [Math]::Min([Math]::Max(1, $Depth), $directoryCount)
        $group = @($segments[0..($take - 1)]) -join '/'
    } else {
        $stem = [IO.Path]::GetFileNameWithoutExtension($RelativePath).ToLowerInvariant()
        $stem = $stem -replace '(?i)([_\-\s]*(final|final-delivery|最终|成品|精简版|扩展版|内部评估版|改写版|报告书版|v\d+))+$', ''
        $group = if ($stem) { '[root]:' + $stem } else { '[root]' }
    }
    return $SourceId + '::' + $group.ToLowerInvariant()
}

function Get-QueuedPriority {
    param(
        [object]$Item,
        [object]$Config
    )
    $score = [int]$Item.priority
    $lowerName = ([IO.Path]::GetFileName([string]$Item.relativePath)).ToLowerInvariant()
    $lowerPath = ([string]$Item.relativePath).ToLowerInvariant()
    if ($Config.scanPolicy.PSObject.Properties.Name -contains 'lowValueNameFragments') {
        foreach ($fragment in @($Config.scanPolicy.lowValueNameFragments)) {
            if ($lowerName.Contains(([string]$fragment).ToLowerInvariant())) {
                $score -= 30
                break
            }
        }
    }
    if ($Config.scanPolicy.PSObject.Properties.Name -contains 'lowValueDirectoryFragments') {
        foreach ($fragment in @($Config.scanPolicy.lowValueDirectoryFragments)) {
            if ($lowerPath.Contains(([string]$fragment).ToLowerInvariant())) {
                $score -= 20
                break
            }
        }
    }
    return $score
}

function Invoke-Scan {
    param(
        [object]$Config,
        [hashtable]$Paths
    )

    Assert-Doctor $Config
    $state = Get-State $Paths
    $queue = Get-Queue $Paths
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($savedItem in @($queue.items)) {
        $items.Add($savedItem)
    }

    $knownIds = @{}
    foreach ($item in $items) {
        $knownIds[[string]$item.id] = $true
    }

    $sourceStates = [System.Collections.Generic.List[object]]::new()
    foreach ($savedSource in @($state.sources)) {
        $sourceStates.Add($savedSource)
    }

    $added = 0
    $superseded = 0
    $sourceResults = [System.Collections.Generic.List[object]]::new()

    foreach ($source in @($Config.semanticSources)) {
        $sourceId = [string]$source.id
        $topicMode = if ($source.PSObject.Properties.Name -contains 'topicGrouping') {
            [string]$source.topicGrouping
        } else {
            'top-level'
        }
        $topicDepth = if ($source.PSObject.Properties.Name -contains 'topicDepth') {
            [int]$source.topicDepth
        } else {
            1
        }
        $sourceRoot = Normalize-Path ([string]$source.path)
        $scanCutoffUtc = [DateTime]::UtcNow.AddMinutes(-[int]$Config.scanPolicy.stableMinutes)
        $sourceState = @($sourceStates | Where-Object { [string]$_.id -eq $sourceId } | Select-Object -First 1)
        if ($sourceState.Count -gt 0) {
            $cursorUtc = [DateTime]::Parse([string]$sourceState[0].cursorUtc).ToUniversalTime()
        } else {
            $cursorUtc = [DateTime]::UtcNow.AddDays(-[int]$Config.scanPolicy.initialLookbackDays)
        }

        $sourceAdded = 0
        $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Length -gt 0 -and
            $_.LastWriteTimeUtc -gt $cursorUtc -and
            $_.LastWriteTimeUtc -le $scanCutoffUtc -and
            -not (Test-ExcludedFile $_ $sourceRoot $Config)
        })

        foreach ($file in $files) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            $identity = '{0}|{1}|{2}|{3}' -f $sourceId, $relative.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks
            $id = Get-HashString $identity
            if ($knownIds.ContainsKey($id)) {
                continue
            }

            foreach ($older in @($items | Where-Object {
                [string]$_.sourceId -eq $sourceId -and
                [string]$_.relativePath -eq $relative -and
                [string]$_.status -eq 'pending'
            })) {
                $older.status = 'superseded'
                $older.supersededBy = $id
                $superseded++
            }

            $items.Add([PSCustomObject][ordered]@{
                id = $id
                sourceId = $sourceId
                sourceLabel = [string]$source.label
                sourceRoot = $sourceRoot
                relativePath = $relative
                topicKey = Get-TopicKey $sourceId $relative $topicMode $topicDepth
                fullPath = $file.FullName
                extension = $file.Extension.ToLowerInvariant()
                sizeBytes = $file.Length
                modifiedUtc = $file.LastWriteTimeUtc.ToString('o')
                discoveredUtc = [DateTime]::UtcNow.ToString('o')
                priority = Get-Priority $file $Config
                status = 'pending'
                consentStatus = if (Test-SensitivePath $relative $Config) { 'required' } else { 'not-required' }
                processedUtc = $null
                supersededBy = $null
                error = $null
            })
            $knownIds[$id] = $true
            $added++
            $sourceAdded++
        }

        $existingState = @($sourceStates | Where-Object { [string]$_.id -eq $sourceId } | Select-Object -First 1)
        if ($existingState.Count -gt 0) {
            $existingState[0].cursorUtc = $scanCutoffUtc.ToString('o')
            $existingState[0].lastScanUtc = [DateTime]::UtcNow.ToString('o')
            $existingState[0].lastError = $null
        } else {
            $sourceStates.Add([PSCustomObject][ordered]@{
                id = $sourceId
                cursorUtc = $scanCutoffUtc.ToString('o')
                lastScanUtc = [DateTime]::UtcNow.ToString('o')
                lastError = $null
            })
        }
        $sourceResults.Add([PSCustomObject]@{
            sourceId = $sourceId
            enqueued = $sourceAdded
            cursorUtc = $scanCutoffUtc.ToString('o')
        })
    }

    $queueToSave = [ordered]@{
        schemaVersion = 1
        items = @($items)
    }
    $stateToSave = [ordered]@{
        schemaVersion = 1
        sources = @($sourceStates)
    }
    Write-JsonAtomic $Paths.queue $queueToSave
    Write-JsonAtomic $Paths.state $stateToSave

    return [ordered]@{
        status = 'OK'
        enqueued = $added
        superseded = $superseded
        pending = @($items | Where-Object { [string]$_.status -eq 'pending' }).Count
        requiresConsent = @($items | Where-Object {
            [string]$_.status -eq 'pending' -and
            $_.PSObject.Properties.Name -contains 'consentStatus' -and
            [string]$_.consentStatus -eq 'required'
        }).Count
        sources = @($sourceResults)
    }
}

function Get-FairBatch {
    param(
        [object[]]$Pending,
        [int]$FileLimit,
        [int]$TopicLimit,
        [int]$FilesPerTopic,
        [object]$Config
    )

    $topicGroups = [System.Collections.Generic.List[object]]::new()
    $sourceModes = @{}
    $sourceDepths = @{}
    foreach ($source in @($Config.semanticSources)) {
        $sourceModes[[string]$source.id] = if ($source.PSObject.Properties.Name -contains 'topicGrouping') {
            [string]$source.topicGrouping
        } else {
            'top-level'
        }
        $sourceDepths[[string]$source.id] = if ($source.PSObject.Properties.Name -contains 'topicDepth') {
            [int]$source.topicDepth
        } else {
            1
        }
    }
    foreach ($item in $Pending) {
        $mode = if ($sourceModes.ContainsKey([string]$item.sourceId)) { $sourceModes[[string]$item.sourceId] } else { 'top-level' }
        $depth = if ($sourceDepths.ContainsKey([string]$item.sourceId)) { [int]$sourceDepths[[string]$item.sourceId] } else { 1 }
        $topicKey = Get-TopicKey ([string]$item.sourceId) ([string]$item.relativePath) $mode $depth
        Add-Member -InputObject $item -NotePropertyName effectiveTopicKey -NotePropertyValue $topicKey -Force
        Add-Member -InputObject $item -NotePropertyName effectivePriority -NotePropertyValue (Get-QueuedPriority $item $Config) -Force
    }

    foreach ($group in @($Pending | Group-Object effectiveTopicKey)) {
        $orderedItems = @($group.Group | Sort-Object @{Expression = 'effectivePriority'; Descending = $true}, @{Expression = 'modifiedUtc'; Descending = $true})
        $topicGroups.Add([PSCustomObject]@{
            topicKey = $group.Name
            sourceId = [string]$orderedItems[0].sourceId
            sourceLabel = [string]$orderedItems[0].sourceLabel
            maxPriority = [int](($orderedItems | Measure-Object effectivePriority -Maximum).Maximum)
            latestModifiedUtc = [string](($orderedItems | Sort-Object modifiedUtc -Descending | Select-Object -First 1).modifiedUtc)
            allItems = $orderedItems
        })
    }

    $sourceBuckets = @{}
    foreach ($group in @($topicGroups | Group-Object sourceId)) {
        $sourceBuckets[$group.Name] = [System.Collections.Queue]::new()
        foreach ($topic in @($group.Group | Sort-Object @{Expression = 'maxPriority'; Descending = $true}, @{Expression = 'latestModifiedUtc'; Descending = $true})) {
            $sourceBuckets[$group.Name].Enqueue($topic)
        }
    }

    $selectedTopics = [System.Collections.Generic.List[object]]::new()
    $sourceOrder = @($sourceBuckets.Keys | Sort-Object)
    while ($selectedTopics.Count -lt $TopicLimit) {
        $addedThisRound = 0
        foreach ($sourceId in $sourceOrder) {
            if ($selectedTopics.Count -ge $TopicLimit) {
                break
            }
            if ($sourceBuckets[$sourceId].Count -gt 0) {
                $selectedTopics.Add($sourceBuckets[$sourceId].Dequeue())
                $addedThisRound++
            }
        }
        if ($addedThisRound -eq 0) {
            break
        }
    }

    $selectedItems = [System.Collections.Generic.List[object]]::new()
    $topicResults = [System.Collections.Generic.List[object]]::new()
    foreach ($topic in $selectedTopics) {
        $topicItems = @($topic.allItems | Select-Object -First $FilesPerTopic)
        $remainingCapacity = $FileLimit - $selectedItems.Count
        if ($remainingCapacity -le 0) {
            break
        }
        $topicItems = @($topicItems | Select-Object -First $remainingCapacity)
        foreach ($item in $topicItems) {
            $selectedItems.Add($item)
        }
        $topicResults.Add([PSCustomObject]@{
            topicKey = $topic.topicKey
            sourceId = $topic.sourceId
            sourceLabel = $topic.sourceLabel
            pendingFileCount = $topic.allItems.Count
            selectedFileCount = $topicItems.Count
            items = $topicItems
        })
    }
    return [ordered]@{
        topics = @($topicResults)
        items = @($selectedItems)
    }
}

function Invoke-Next {
    param(
        [object]$Config,
        [hashtable]$Paths
    )
    Assert-Doctor $Config
    $queue = Get-Queue $Paths
    $allPending = @($queue.items | Where-Object { [string]$_.status -eq 'pending' })
    $requiresConsent = @($allPending | Where-Object {
        $consent = if ($_.PSObject.Properties.Name -contains 'consentStatus') { [string]$_.consentStatus } else { '' }
        $isSensitive = Test-SensitivePath ([string]$_.relativePath) $Config
        $isSensitive -and $consent -ne 'approved'
    })
    $pending = @($allPending | Where-Object {
        $consent = if ($_.PSObject.Properties.Name -contains 'consentStatus') { [string]$_.consentStatus } else { '' }
        -not (Test-SensitivePath ([string]$_.relativePath) $Config) -or $consent -eq 'approved'
    })
    $fileLimit = [int]$Config.scanPolicy.maxFilesPerBatch
    $topicLimit = [int]$Config.scanPolicy.maxTopicsPerRun
    $filesPerTopic = if ($Config.scanPolicy.PSObject.Properties.Name -contains 'maxFilesPerTopic') {
        [int]$Config.scanPolicy.maxFilesPerTopic
    } else {
        [Math]::Max(1, [Math]::Floor($fileLimit / [Math]::Max(1, $topicLimit)))
    }
    $selection = Get-FairBatch $pending $fileLimit $topicLimit $filesPerTopic $Config
    $selected = @($selection.items)
    return [ordered]@{
        status = if ($selected.Count -gt 0) { 'READY' } else { 'NO_PENDING' }
        count = $selected.Count
        topicCount = @($selection.topics).Count
        maxTopicsPerRun = $topicLimit
        remainingAfterBatch = [Math]::Max(0, $pending.Count - $selected.Count)
        requiresConsentCount = $requiresConsent.Count
        requiresConsent = @($requiresConsent | Select-Object id, sourceId, sourceLabel, relativePath, modifiedUtc)
        topics = @($selection.topics)
        items = $selected
    }
}

function Invoke-Approve {
    param(
        [hashtable]$Paths,
        [string[]]$Ids
    )
    if ($Ids.Count -eq 0) {
        throw 'Approve requires at least one ItemIds value.'
    }
    $queue = Get-Queue $Paths
    $idSet = @{}
    foreach ($id in $Ids) {
        $idSet[[string]$id] = $true
    }
    $found = @{}
    foreach ($item in @($queue.items)) {
        if ($idSet.ContainsKey([string]$item.id)) {
            Add-Member -InputObject $item -NotePropertyName consentStatus -NotePropertyValue 'approved' -Force
            $found[[string]$item.id] = $true
        }
    }
    $missing = @($Ids | Where-Object { -not $found.ContainsKey([string]$_) })
    if ($missing.Count -gt 0) {
        throw ('Unknown queue IDs: ' + ($missing -join ', '))
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        approved = $Ids.Count
    }
}

function Invoke-Ack {
    param(
        [hashtable]$Paths,
        [string[]]$Ids
    )
    if ($Ids.Count -eq 0) {
        throw 'Ack requires at least one ItemIds value.'
    }
    $queue = Get-Queue $Paths
    $idSet = @{}
    foreach ($id in $Ids) {
        $idSet[[string]$id] = $true
    }
    $found = @{}
    foreach ($item in @($queue.items)) {
        if ($idSet.ContainsKey([string]$item.id)) {
            if ([string]$item.status -eq 'pending') {
                $item.status = 'processed'
                $item.processedUtc = [DateTime]::UtcNow.ToString('o')
                $item.error = $null
            }
            $found[[string]$item.id] = $true
        }
    }
    $missing = @($Ids | Where-Object { -not $found.ContainsKey([string]$_) })
    if ($missing.Count -gt 0) {
        throw ('Unknown queue IDs: ' + ($missing -join ', '))
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        acknowledged = $Ids.Count
    }
}

function Invoke-Status {
    param(
        [hashtable]$Paths,
        [object]$Config
    )
    $queue = Get-Queue $Paths
    $state = Get-State $Paths
    $counts = [ordered]@{}
    foreach ($statusName in @('pending', 'processed', 'superseded', 'error')) {
        $counts[$statusName] = @($queue.items | Where-Object { [string]$_.status -eq $statusName }).Count
    }
    $counts['requiresConsent'] = @($queue.items | Where-Object {
        [string]$_.status -eq 'pending' -and
        (Test-SensitivePath ([string]$_.relativePath) $Config) -and
        (-not ($_.PSObject.Properties.Name -contains 'consentStatus') -or [string]$_.consentStatus -ne 'approved')
    }).Count
    return [ordered]@{
        status = 'OK'
        counts = $counts
        sources = @($state.sources)
    }
}

function Invoke-Discover {
    param([object]$Config)
    if ($Config.discovery.consentGranted -ne $true) {
        throw 'Discovery requires explicit consent: discovery.consentGranted must be true.'
    }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($rootEntry in @($Config.discovery.roots)) {
        $root = Normalize-Path ([string]$rootEntry)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $results.Add([PSCustomObject]@{ root = $root; status = 'NOT_FOUND' })
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)
        $topGroups = @($files | ForEach-Object {
            $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            if ($relative.Contains('\')) { ($relative -split '\\', 2)[0] } else { '[root]' }
        } | Group-Object | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object {
            [PSCustomObject]@{ name = $_.Name; fileCount = $_.Count }
        })
        $extensions = @($files | Group-Object { $_.Extension.ToLowerInvariant() } | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
            [PSCustomObject]@{ extension = $_.Name; fileCount = $_.Count }
        })
        $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        $results.Add([PSCustomObject]@{
            root = $root
            status = 'OK'
            fileCount = $files.Count
            latestModifiedUtc = if ($latest) { $latest.LastWriteTimeUtc.ToString('o') } else { $null }
            topGroups = $topGroups
            extensions = $extensions
        })
    }
    return [ordered]@{
        status = 'OK'
        contentRead = $false
        roots = @($results)
    }
}

$config = Get-Config
$paths = Get-DataPaths $config

$result = switch ($Command) {
    'Doctor' { Invoke-Doctor $config }
    'Init' {
        Assert-Doctor $config
        if (-not (Test-Path -LiteralPath $paths.root -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.root -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $paths.state -PathType Leaf)) {
            Write-JsonAtomic $paths.state (New-EmptyState)
        }
        if (-not (Test-Path -LiteralPath $paths.queue -PathType Leaf)) {
            Write-JsonAtomic $paths.queue (New-EmptyQueue)
        }
        [ordered]@{ status = 'OK'; initialized = $paths.root }
    }
    'Scan' { Invoke-Scan $config $paths }
    'Next' { Invoke-Next $config $paths }
    'Approve' { Invoke-Approve $paths $ItemIds }
    'Ack' { Invoke-Ack $paths $ItemIds }
    'Status' { Invoke-Status $paths $config }
    'Discover' { Invoke-Discover $config }
}

$result | ConvertTo-Json -Depth 12
