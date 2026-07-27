param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('NewConfig', 'Doctor', 'Init', 'Scan', 'Next', 'Approve', 'Ack', 'Fail', 'Requeue', 'Status', 'Report', 'Compact', 'Discover', 'Inbox', 'InboxClear')]
    [string]$Command,

    [string]$ConfigPath = '',

    [string]$TargetPath = '',

    [string[]]$ItemIds = @(),

    [string]$Reason = '',

    [int]$OlderThanDays = 30,

    [int]$PruneBackupsOlderThanDays = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

. (Join-Path $PSScriptRoot 'common.ps1')

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
        archive = Join-Path $root 'queue-archive.local.json'
        backups = Join-Path $root 'backups'
        reports = Join-Path $root 'reports'
        inboxArchive = Join-Path $root 'inbox-archive'
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
    if (-not $saved -or -not (Test-HasProperty $saved 'sources')) {
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
    if (-not $saved -or -not (Test-HasProperty $saved 'items')) {
        return New-EmptyQueue
    }
    return [ordered]@{
        schemaVersion = 1
        items = @($saved.items)
    }
}

function New-ScanContext {
    # Lower-cases every configured list once so per-file checks stay cheap,
    # and tolerates missing config sections instead of crashing mid-scan.
    param([object]$Config)

    $privacy = $null
    if (Test-HasProperty $Config 'privacy') {
        $privacy = $Config.privacy
    }
    $scanPolicy = $null
    if (Test-HasProperty $Config 'scanPolicy') {
        $scanPolicy = $Config.scanPolicy
    }

    $context = @{
        ignoredDirs = @()
        ignoredFiles = @()
        ignoredFragments = @()
        sensitiveFragments = @()
        excludedPaths = @()
        allowed = @()
        highExtensions = @()
        highFragments = @()
        lowNameFragments = @()
        lowDirFragments = @()
        maxBytes = [long]::MaxValue
    }
    if (Test-HasProperty $privacy 'ignoredDirectories') {
        $context.ignoredDirs = @($privacy.ignoredDirectories | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $privacy 'ignoredFileNames') {
        $context.ignoredFiles = @($privacy.ignoredFileNames | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $privacy 'ignoredNameFragments') {
        $context.ignoredFragments = @($privacy.ignoredNameFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $privacy 'sensitiveNameFragments') {
        $context.sensitiveFragments = @($privacy.sensitiveNameFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $privacy 'excludedPaths') {
        $context.excludedPaths = @($privacy.excludedPaths | ForEach-Object { [string]$_ })
    }
    if (Test-HasProperty $scanPolicy 'allowedExtensions') {
        $context.allowed = @($scanPolicy.allowedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $scanPolicy 'highValueExtensions') {
        $context.highExtensions = @($scanPolicy.highValueExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $scanPolicy 'highValueNameFragments') {
        $context.highFragments = @($scanPolicy.highValueNameFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $scanPolicy 'lowValueNameFragments') {
        $context.lowNameFragments = @($scanPolicy.lowValueNameFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $scanPolicy 'lowValueDirectoryFragments') {
        $context.lowDirFragments = @($scanPolicy.lowValueDirectoryFragments | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if (Test-HasProperty $scanPolicy 'maxSemanticFileBytes') {
        $context.maxBytes = [long]$scanPolicy.maxSemanticFileBytes
    }
    return $context
}

function Invoke-Doctor {
    param([object]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Unknown-key detection guards against silent typos: a misspelled privacy
    # key would otherwise disable protection without any signal.
    $knownRootKeys = @('$schema', 'schemaVersion', 'vaultRoot', 'controllerDataRoot', 'semanticSources', 'metadataOnlySources', 'destinations', 'scanPolicy', 'privacy', 'discovery', 'features')
    $knownScanPolicyKeys = @('stableMinutes', 'initialLookbackDays', 'maxFilesPerBatch', 'maxTopicsPerRun', 'maxFilesPerTopic', 'maxSemanticFileBytes', 'allowedExtensions', 'highValueExtensions', 'highValueNameFragments', 'lowValueNameFragments', 'lowValueDirectoryFragments')
    $knownPrivacyKeys = @('ignoredDirectories', 'ignoredFileNames', 'ignoredNameFragments', 'sensitiveNameFragments', 'excludedPaths')
    $knownSemanticKeys = @('id', 'label', 'path', 'topicGrouping', 'topicDepth')
    $knownMetadataKeys = @('id', 'label', 'path', 'destination', 'readFileContents', 'title', 'includeRelativePrefixes', 'ignoredDirectories', 'stripPrefixSegments', 'groupDepth', 'allowedExtensions')
    $knownDiscoveryKeys = @('consentGranted', 'roots')

    foreach ($name in @($Config.PSObject.Properties.Name)) {
        if (-not ($knownRootKeys -contains $name)) {
            $warnings.Add("Unknown config key: $name")
        }
    }

    if (-not (Test-HasProperty $Config 'schemaVersion') -or [int]$Config.schemaVersion -ne 1) {
        $errors.Add('Unsupported schemaVersion. Expected 1.')
    }
    if (-not (Test-HasProperty $Config 'vaultRoot') -or -not $Config.vaultRoot) {
        $errors.Add('vaultRoot is required.')
    } elseif (-not (Test-Path -LiteralPath ([string]$Config.vaultRoot) -PathType Container)) {
        $errors.Add("Vault not found: $($Config.vaultRoot)")
    }
    if (-not (Test-HasProperty $Config 'controllerDataRoot') -or -not $Config.controllerDataRoot) {
        $errors.Add('controllerDataRoot is required.')
    }

    $sources = @()
    if (Test-HasProperty $Config 'semanticSources') {
        $sources = @($Config.semanticSources)
    }
    if ($sources.Count -eq 0) {
        $errors.Add('At least one semanticSources entry is required.')
    }

    $ids = @{}
    $reachable = 0
    foreach ($source in $sources) {
        foreach ($name in @($source.PSObject.Properties.Name)) {
            if (-not ($knownSemanticKeys -contains $name)) {
                $warnings.Add("Unknown semantic source key: $name")
            }
        }
        $id = ''
        if (Test-HasProperty $source 'id') {
            $id = [string]$source.id
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add('Every semantic source requires an id.')
            continue
        }
        if ($ids.ContainsKey($id.ToLowerInvariant())) {
            $errors.Add("Duplicate source id: $id")
        } else {
            $ids[$id.ToLowerInvariant()] = $true
        }
        if (-not (Test-HasProperty $source 'path') -or -not $source.path) {
            $errors.Add("Semantic source '$id' requires a path.")
        } elseif (-not (Test-Path -LiteralPath ([string]$source.path) -PathType Container)) {
            # A cloud drive that is not mounted right now should not kill the
            # whole weekly run; Scan skips unreachable roots without moving
            # their cursor, so nothing is lost.
            $warnings.Add("Source not found (Scan will skip it without losing work): $($source.path)")
        } else {
            $reachable++
        }
    }
    if ($sources.Count -gt 0 -and $reachable -eq 0) {
        $errors.Add('No semantic source root is currently reachable.')
    }

    if ((Test-HasProperty $Config 'vaultRoot') -and $Config.vaultRoot -and (Test-HasProperty $Config 'controllerDataRoot') -and $Config.controllerDataRoot) {
        $vault = Normalize-Path ([string]$Config.vaultRoot)
        $dataRoot = Normalize-Path ([string]$Config.controllerDataRoot)
        if ((Test-PathWithin $dataRoot $vault) -or (Test-PathWithin $vault $dataRoot)) {
            $errors.Add('controllerDataRoot and vaultRoot must not contain each other.')
        }
    }

    for ($i = 0; $i -lt $sources.Count; $i++) {
        if (-not (Test-HasProperty $sources[$i] 'path') -or -not $sources[$i].path) {
            continue
        }
        $a = [string]$sources[$i].path
        for ($j = $i + 1; $j -lt $sources.Count; $j++) {
            if (-not (Test-HasProperty $sources[$j] 'path') -or -not $sources[$j].path) {
                continue
            }
            $b = [string]$sources[$j].path
            if ((Test-PathWithin $a $b) -or (Test-PathWithin $b $a)) {
                $errors.Add("Semantic source roots overlap: $a | $b")
            }
        }
        if ((Test-HasProperty $Config 'vaultRoot') -and $Config.vaultRoot) {
            $vaultPath = [string]$Config.vaultRoot
            if ((Test-PathWithin $a $vaultPath) -or (Test-PathWithin $vaultPath $a)) {
                $errors.Add("Semantic source and vault overlap: $a")
            }
        }
        if ((Test-HasProperty $Config 'controllerDataRoot') -and $Config.controllerDataRoot) {
            $dataPath = [string]$Config.controllerDataRoot
            if ((Test-PathWithin $a $dataPath) -or (Test-PathWithin $dataPath $a)) {
                $errors.Add("Semantic source and controllerDataRoot overlap: $a")
            }
        }
    }

    $metadataSources = @()
    if (Test-HasProperty $Config 'metadataOnlySources') {
        $metadataSources = @($Config.metadataOnlySources)
    }
    $metadataIds = @{}
    foreach ($source in $metadataSources) {
        foreach ($name in @($source.PSObject.Properties.Name)) {
            if (-not ($knownMetadataKeys -contains $name)) {
                $warnings.Add("Unknown metadata source key: $name")
            }
        }
        $id = ''
        if (Test-HasProperty $source 'id') {
            $id = [string]$source.id
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add('Every metadata-only source requires an id.')
            continue
        }
        if ($metadataIds.ContainsKey($id.ToLowerInvariant())) {
            $errors.Add("Duplicate metadata source id: $id")
        } else {
            $metadataIds[$id.ToLowerInvariant()] = $true
        }
        if (-not (Test-HasProperty $source 'readFileContents') -or $source.readFileContents -ne $false) {
            $errors.Add("Metadata source '$id' must set readFileContents=false.")
        }
        if (-not (Test-HasProperty $source 'destination') -or -not $source.destination) {
            $errors.Add("Metadata source '$id' requires a destination.")
        } elseif ([IO.Path]::IsPathRooted([string]$source.destination)) {
            # Join-Path does not honor a rooted child, so an absolute
            # destination would slip past the containment check (PS7) or make
            # GetFullPath throw (PS5.1). Reject it outright.
            $errors.Add("Metadata destination must be relative to the vault: $($source.destination)")
        } elseif ((Test-HasProperty $Config 'vaultRoot') -and $Config.vaultRoot) {
            $destination = $null
            try {
                $destination = Normalize-Path (Join-Path ([string]$Config.vaultRoot) ([string]$source.destination))
            } catch {
                $errors.Add("Metadata destination is invalid: $($source.destination)")
            }
            if ($destination -and -not (Test-PathWithin $destination ([string]$Config.vaultRoot))) {
                $errors.Add("Metadata destination is outside the vault: $($source.destination)")
            }
        }
        if ((Test-HasProperty $source 'path') -and $source.path) {
            if (-not (Test-Path -LiteralPath ([string]$source.path) -PathType Container)) {
                $warnings.Add("Metadata source not found: $($source.path)")
            }
            foreach ($semantic in $sources) {
                if (-not (Test-HasProperty $semantic 'path') -or -not $semantic.path) {
                    continue
                }
                $metadataPath = [string]$source.path
                $semanticPath = [string]$semantic.path
                if ((Test-PathWithin $metadataPath $semanticPath) -or (Test-PathWithin $semanticPath $metadataPath)) {
                    $errors.Add("Metadata-only source overlaps a semantic source (its contents would be read): $metadataPath | $semanticPath")
                }
            }
        } else {
            $errors.Add("Metadata source '$id' requires a path.")
        }
    }

    $scanPolicy = $null
    if (Test-HasProperty $Config 'scanPolicy') {
        $scanPolicy = $Config.scanPolicy
        foreach ($name in @($scanPolicy.PSObject.Properties.Name)) {
            if (-not ($knownScanPolicyKeys -contains $name)) {
                $warnings.Add("Unknown scanPolicy key: $name")
            }
        }
    } else {
        $errors.Add('scanPolicy section is required.')
    }
    if ($scanPolicy) {
        foreach ($field in @('stableMinutes', 'initialLookbackDays', 'maxFilesPerBatch', 'maxTopicsPerRun', 'maxSemanticFileBytes')) {
            if (-not (Test-HasProperty $scanPolicy $field)) {
                $errors.Add("scanPolicy.$field is required.")
            }
        }
        if ((Test-HasProperty $scanPolicy 'maxFilesPerBatch') -and [int]$scanPolicy.maxFilesPerBatch -lt 1) {
            $errors.Add('scanPolicy.maxFilesPerBatch must be greater than zero.')
        }
        if ((Test-HasProperty $scanPolicy 'maxTopicsPerRun') -and [int]$scanPolicy.maxTopicsPerRun -lt 1) {
            $errors.Add('scanPolicy.maxTopicsPerRun must be greater than zero.')
        }
        if ((Test-HasProperty $scanPolicy 'maxSemanticFileBytes') -and [long]$scanPolicy.maxSemanticFileBytes -lt 1024) {
            $warnings.Add('maxSemanticFileBytes is unusually small.')
        }
        if (-not (Test-HasProperty $scanPolicy 'allowedExtensions') -or @($scanPolicy.allowedExtensions).Count -eq 0) {
            $errors.Add('scanPolicy.allowedExtensions must list at least one extension.')
        }
        if (Test-HasProperty $scanPolicy 'maxFilesPerTopic') {
            if ([int]$scanPolicy.maxFilesPerTopic -lt 1) {
                $errors.Add('scanPolicy.maxFilesPerTopic must be greater than zero.')
            } elseif ((Test-HasProperty $scanPolicy 'maxFilesPerBatch') -and (Test-HasProperty $scanPolicy 'maxTopicsPerRun') -and
                ([int]$scanPolicy.maxFilesPerTopic * [int]$scanPolicy.maxTopicsPerRun) -gt [int]$scanPolicy.maxFilesPerBatch) {
                $warnings.Add('maxFilesPerTopic * maxTopicsPerRun exceeds maxFilesPerBatch; early topics can consume the whole batch and delay other sources.')
            }
        }
    }

    if (Test-HasProperty $Config 'privacy') {
        foreach ($name in @($Config.privacy.PSObject.Properties.Name)) {
            if (-not ($knownPrivacyKeys -contains $name)) {
                $warnings.Add("Unknown privacy key: $name")
            }
        }
        if (-not (Test-HasProperty $Config.privacy 'sensitiveNameFragments') -or @($Config.privacy.sensitiveNameFragments).Count -eq 0) {
            $warnings.Add('privacy.sensitiveNameFragments is empty; no filename-based consent quarantine will apply.')
        }
    } else {
        $warnings.Add('privacy section is missing; no exclusions will apply.')
    }

    if (Test-HasProperty $Config 'discovery') {
        foreach ($name in @($Config.discovery.PSObject.Properties.Name)) {
            if (-not ($knownDiscoveryKeys -contains $name)) {
                $warnings.Add("Unknown discovery key: $name")
            }
        }
    }

    $knownFeaturesKeys = @('creatorInsights')
    $knownCreatorKeys = @('enabled', 'focusAreas', 'input')
    $creator = $null
    if (Test-HasProperty $Config 'features') {
        foreach ($name in @($Config.features.PSObject.Properties.Name)) {
            if (-not ($knownFeaturesKeys -contains $name)) {
                $warnings.Add("Unknown features key: $name")
            }
        }
        if (Test-HasProperty $Config.features 'creatorInsights') {
            $creator = $Config.features.creatorInsights
        }
    }
    if ($creator) {
        foreach ($name in @($creator.PSObject.Properties.Name)) {
            if (-not ($knownCreatorKeys -contains $name)) {
                $warnings.Add("Unknown creatorInsights key: $name")
            }
        }
    }
    if ($creator -and (Test-HasProperty $creator 'enabled') -and $creator.enabled -eq $true) {
        $insightsInput = ''
        if (Test-HasProperty $creator 'input') {
            $insightsInput = [string]$creator.input
        }
        if ($insightsInput -ne 'distilled-notes-only') {
            $errors.Add('Creator insights must use distilled-notes-only input.')
        }
    }

    return [ordered]@{
        status = if ($errors.Count -eq 0) { 'OK' } else { 'ERROR' }
        errors = @($errors)
        warnings = @($warnings)
        semanticSourceCount = $sources.Count
        reachableSemanticSources = $reachable
        metadataSourceCount = $metadataSources.Count
        vaultRoot = if (Test-HasProperty $Config 'vaultRoot') { [string]$Config.vaultRoot } else { $null }
        controllerDataRoot = if (Test-HasProperty $Config 'controllerDataRoot') { [string]$Config.controllerDataRoot } else { $null }
    }
}

function Assert-Doctor {
    param([object]$Config)
    $result = Invoke-Doctor $Config
    if ($result.status -ne 'OK') {
        throw ('Doctor failed: ' + ($result.errors -join '; '))
    }
}

function Test-ExcludedFileFast {
    # Directory-level exclusions are handled by the pruned walk; this covers
    # the file-level rules only.
    param(
        [IO.FileInfo]$File,
        [hashtable]$Context
    )
    $lowerName = $File.Name.ToLowerInvariant()
    if ($lowerName.StartsWith('~$')) {
        return $true
    }
    if ($Context.ignoredFiles -contains $lowerName) {
        return $true
    }
    foreach ($fragment in $Context.ignoredFragments) {
        if ($lowerName.Contains($fragment)) {
            return $true
        }
    }
    if (-not ($Context.allowed -contains $File.Extension.ToLowerInvariant())) {
        return $true
    }
    foreach ($excluded in $Context.excludedPaths) {
        if (Test-PathWithin $File.FullName $excluded) {
            return $true
        }
    }
    return $false
}

function Get-Priority {
    param(
        [IO.FileInfo]$File,
        [hashtable]$Context
    )
    $score = 0
    if ($Context.highExtensions -contains $File.Extension.ToLowerInvariant()) {
        $score += 50
    }
    $lowerName = $File.Name.ToLowerInvariant()
    foreach ($fragment in $Context.highFragments) {
        if ($lowerName.Contains($fragment)) {
            $score += 50
            break
        }
    }
    return $score
}

function Test-SensitivePath {
    param(
        [string]$RelativePath,
        [hashtable]$Context
    )
    $lowerPath = $RelativePath.ToLowerInvariant()
    foreach ($fragment in $Context.sensitiveFragments) {
        if ($lowerPath.Contains($fragment)) {
            return $true
        }
    }
    return $false
}

function Test-ExcludedQueuedItem {
    # Re-checks a queued item against the LIVE excludedPaths so that adding a
    # path to privacy.excludedPaths retroactively stops already-queued files,
    # matching how sensitiveNameFragments are re-evaluated on every run.
    param(
        [object]$Item,
        [hashtable]$Context
    )
    foreach ($excluded in $Context.excludedPaths) {
        if (Test-PathWithin ([string]$Item.fullPath) $excluded) {
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
        [hashtable]$Context
    )
    $score = [int]$Item.priority
    $lowerName = ([IO.Path]::GetFileName([string]$Item.relativePath)).ToLowerInvariant()
    $lowerPath = ([string]$Item.relativePath).ToLowerInvariant()
    foreach ($fragment in $Context.lowNameFragments) {
        if ($lowerName.Contains($fragment)) {
            $score -= 30
            break
        }
    }
    foreach ($fragment in $Context.lowDirFragments) {
        if ($lowerPath.Contains($fragment)) {
            $score -= 20
            break
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
    $context = New-ScanContext $Config
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
    $unreachableSources = @{}

    foreach ($source in @($Config.semanticSources)) {
        $sourceId = [string]$source.id
        $topicMode = if (Test-HasProperty $source 'topicGrouping') { [string]$source.topicGrouping } else { 'top-level' }
        $topicDepth = if (Test-HasProperty $source 'topicDepth') { [int]$source.topicDepth } else { 1 }
        $sourceRoot = Normalize-Path ([string]$source.path)
        $existingState = @($sourceStates | Where-Object { [string]$_.id -eq $sourceId } | Select-Object -First 1)

        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            # Unreachable root (unmounted cloud drive, renamed folder): skip it
            # without advancing the cursor so nothing is silently lost.
            if ($existingState.Count -gt 0) {
                Set-ObjectProperty $existingState[0] 'lastScanUtc' ([DateTime]::UtcNow.ToString('o'))
                Set-ObjectProperty $existingState[0] 'lastError' 'SOURCE_NOT_FOUND: root unreachable; cursor unchanged.'
            } else {
                $sourceStates.Add([PSCustomObject][ordered]@{
                    id = $sourceId
                    cursorUtc = $null
                    lastScanUtc = [DateTime]::UtcNow.ToString('o')
                    lastError = 'SOURCE_NOT_FOUND: root unreachable; cursor unchanged.'
                })
            }
            $sourceResults.Add([PSCustomObject]@{
                sourceId = $sourceId
                status = 'SKIPPED'
                enqueued = 0
                error = 'SOURCE_NOT_FOUND'
            })
            $unreachableSources[$sourceId] = $true
            continue
        }

        $scanCutoffUtc = [DateTime]::UtcNow.AddMinutes(-[int]$Config.scanPolicy.stableMinutes)
        if ($existingState.Count -gt 0 -and (Test-HasProperty $existingState[0] 'cursorUtc') -and $existingState[0].cursorUtc) {
            $cursorUtc = [DateTime]::Parse([string]$existingState[0].cursorUtc).ToUniversalTime()
        } else {
            $cursorUtc = [DateTime]::UtcNow.AddDays(-[int]$Config.scanPolicy.initialLookbackDays)
        }

        $inaccessible = 0
        $walkError = $null
        $candidates = @()
        try {
            $candidates = Get-CandidateFiles -Root $sourceRoot -IgnoredDirectoryNames $context.ignoredDirs -InaccessibleCount ([ref]$inaccessible)
        } catch {
            $walkError = $_.Exception.Message
        }
        if ($walkError) {
            if ($existingState.Count -gt 0) {
                Set-ObjectProperty $existingState[0] 'lastScanUtc' ([DateTime]::UtcNow.ToString('o'))
                Set-ObjectProperty $existingState[0] 'lastError' ("SCAN_FAILED: $walkError; cursor unchanged.")
            } else {
                $sourceStates.Add([PSCustomObject][ordered]@{
                    id = $sourceId
                    cursorUtc = $null
                    lastScanUtc = [DateTime]::UtcNow.ToString('o')
                    lastError = "SCAN_FAILED: $walkError; cursor unchanged."
                })
            }
            $sourceResults.Add([PSCustomObject]@{
                sourceId = $sourceId
                status = 'ERROR'
                enqueued = 0
                error = $walkError
            })
            $unreachableSources[$sourceId] = $true
            continue
        }

        $sourceAdded = 0
        foreach ($file in $candidates) {
            if ($file.Length -le 0) {
                continue
            }
            if ($file.LastWriteTimeUtc -le $cursorUtc -or $file.LastWriteTimeUtc -gt $scanCutoffUtc) {
                continue
            }
            if (Test-ExcludedFileFast $file $context) {
                continue
            }

            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            $identity = '{0}|{1}|{2}|{3}' -f $sourceId, $relative.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks
            $id = Get-HashString $identity
            if ($knownIds.ContainsKey($id)) {
                continue
            }

            foreach ($older in @($items | Where-Object {
                [string]$_.sourceId -eq $sourceId -and
                [string]$_.relativePath -eq $relative -and
                (@('pending', 'missing') -contains [string]$_.status)
            })) {
                $older.status = 'superseded'
                Set-ObjectProperty $older 'supersededBy' $id
                Set-ObjectProperty $older 'supersededUtc' ([DateTime]::UtcNow.ToString('o'))
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
                priority = Get-Priority $file $context
                status = 'pending'
                consentStatus = if (Test-SensitivePath $relative $context) { 'required' } else { 'not-required' }
                processedUtc = $null
                supersededBy = $null
                error = $null
            })
            $knownIds[$id] = $true
            $added++
            $sourceAdded++
        }

        # When some directories could not be listed, hold the cursor so their
        # files stay inside the scan window and get retried next run; the
        # identity hash keeps already-enqueued files from duplicating.
        $partialError = $null
        if ($inaccessible -gt 0) {
            $partialError = "PARTIAL: $inaccessible directories could not be listed; cursor held so their files are retried."
        }
        if ($existingState.Count -gt 0) {
            if ($inaccessible -eq 0) {
                Set-ObjectProperty $existingState[0] 'cursorUtc' ($scanCutoffUtc.ToString('o'))
            }
            Set-ObjectProperty $existingState[0] 'lastScanUtc' ([DateTime]::UtcNow.ToString('o'))
            Set-ObjectProperty $existingState[0] 'lastError' $partialError
        } else {
            $newCursor = $null
            if ($inaccessible -eq 0) {
                $newCursor = $scanCutoffUtc.ToString('o')
            }
            $sourceStates.Add([PSCustomObject][ordered]@{
                id = $sourceId
                cursorUtc = $newCursor
                lastScanUtc = [DateTime]::UtcNow.ToString('o')
                lastError = $partialError
            })
        }
        $sourceResults.Add([PSCustomObject]@{
            sourceId = $sourceId
            status = 'OK'
            enqueued = $sourceAdded
            error = $partialError
        })
    }

    # Sweep queued work against the filesystem so deleted or renamed files
    # cannot sit in 'pending' forever; restored files return to 'pending'.
    # Sources whose root was unreachable this run are exempt: an unmounted
    # cloud drive must not flip hundreds of items to 'missing'.
    $missingMarked = 0
    $restored = 0
    foreach ($item in $items) {
        if ($unreachableSources.ContainsKey([string]$item.sourceId)) {
            continue
        }
        $itemStatus = [string]$item.status
        if ($itemStatus -eq 'pending') {
            if (-not (Test-Path -LiteralPath ([string]$item.fullPath) -PathType Leaf)) {
                $item.status = 'missing'
                $missingMarked++
            }
        } elseif ($itemStatus -eq 'missing') {
            if (Test-Path -LiteralPath ([string]$item.fullPath) -PathType Leaf) {
                $item.status = 'pending'
                $restored++
            }
        }
    }

    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($items) })
    Write-JsonAtomic $Paths.state ([ordered]@{ schemaVersion = 1; sources = @($sourceStates) })

    return [ordered]@{
        status = 'OK'
        enqueued = $added
        superseded = $superseded
        missingMarked = $missingMarked
        restored = $restored
        pending = @($items | Where-Object { [string]$_.status -eq 'pending' }).Count
        requiresConsent = @($items | Where-Object {
            if ([string]$_.status -ne 'pending') { return $false }
            $consent = ''
            if (Test-HasProperty $_ 'consentStatus') { $consent = [string]$_.consentStatus }
            (Test-SensitivePath ([string]$_.relativePath) $context) -and $consent -ne 'approved'
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
        [object]$Config,
        [hashtable]$Context
    )

    $topicGroups = [System.Collections.Generic.List[object]]::new()
    $sourceModes = @{}
    $sourceDepths = @{}
    foreach ($source in @($Config.semanticSources)) {
        $sourceModes[[string]$source.id] = if (Test-HasProperty $source 'topicGrouping') { [string]$source.topicGrouping } else { 'top-level' }
        $sourceDepths[[string]$source.id] = if (Test-HasProperty $source 'topicDepth') { [int]$source.topicDepth } else { 1 }
    }
    foreach ($item in $Pending) {
        $mode = if ($sourceModes.ContainsKey([string]$item.sourceId)) { $sourceModes[[string]$item.sourceId] } else { 'top-level' }
        $depth = if ($sourceDepths.ContainsKey([string]$item.sourceId)) { [int]$sourceDepths[[string]$item.sourceId] } else { 1 }
        $topicKey = Get-TopicKey ([string]$item.sourceId) ([string]$item.relativePath) $mode $depth
        Set-ObjectProperty $item 'effectiveTopicKey' $topicKey
        Set-ObjectProperty $item 'effectivePriority' (Get-QueuedPriority $item $Context)
    }

    foreach ($group in @($Pending | Group-Object effectiveTopicKey)) {
        $orderedItems = @($group.Group | Sort-Object @{Expression = 'effectivePriority'; Descending = $true}, @{Expression = 'modifiedUtc'; Descending = $true})
        $topicGroups.Add([PSCustomObject]@{
            topicKey = $group.Name
            sourceId = [string]$orderedItems[0].sourceId
            sourceLabel = [string]$orderedItems[0].sourceLabel
            maxPriority = [int](($orderedItems | Measure-Object effectivePriority -Maximum).Maximum)
            latestModifiedUtc = [string](@($orderedItems | Sort-Object modifiedUtc -Descending)[0].modifiedUtc)
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

    # Serve sources oldest-backlog-first. A fixed alphabetical order starved
    # whichever source sorted last whenever sources outnumbered topic slots;
    # with age-based ordering a source that keeps missing the cut rises to the
    # front of the next run automatically.
    $sourceOldest = @{}
    foreach ($item in $Pending) {
        $sid = [string]$item.sourceId
        $discovered = [string]$item.discoveredUtc
        if (-not $sourceOldest.ContainsKey($sid) -or $discovered -lt $sourceOldest[$sid]) {
            $sourceOldest[$sid] = $discovered
        }
    }
    $sourceOrder = @($sourceBuckets.Keys | Sort-Object @{Expression = { $sourceOldest[$_] }}, @{Expression = { $_ }})

    $selectedTopics = [System.Collections.Generic.List[object]]::new()
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
    $context = New-ScanContext $Config
    $queue = Get-Queue $Paths
    $pendingAll = @($queue.items | Where-Object { [string]$_.status -eq 'pending' })
    $excludedNow = @($pendingAll | Where-Object { Test-ExcludedQueuedItem $_ $context })
    $allPending = @($pendingAll | Where-Object { -not (Test-ExcludedQueuedItem $_ $context) })
    $requiresConsent = @($allPending | Where-Object {
        $consent = ''
        if (Test-HasProperty $_ 'consentStatus') { $consent = [string]$_.consentStatus }
        (Test-SensitivePath ([string]$_.relativePath) $context) -and $consent -ne 'approved'
    })
    $cleared = @($allPending | Where-Object {
        $consent = ''
        if (Test-HasProperty $_ 'consentStatus') { $consent = [string]$_.consentStatus }
        -not (Test-SensitivePath ([string]$_.relativePath) $context) -or $consent -eq 'approved'
    })
    # Oversized files cannot be distilled within the configured read budget;
    # surface them separately instead of letting them clog every batch. Retire
    # them with Fail, or raise maxSemanticFileBytes to include them.
    $oversized = @($cleared | Where-Object { [long]$_.sizeBytes -gt $context.maxBytes })
    $eligible = @($cleared | Where-Object { [long]$_.sizeBytes -le $context.maxBytes })

    $fileLimit = [int]$Config.scanPolicy.maxFilesPerBatch
    $topicLimit = [int]$Config.scanPolicy.maxTopicsPerRun
    $filesPerTopic = if (Test-HasProperty $Config.scanPolicy 'maxFilesPerTopic') {
        [int]$Config.scanPolicy.maxFilesPerTopic
    } else {
        [Math]::Max(1, [Math]::Floor($fileLimit / [Math]::Max(1, $topicLimit)))
    }
    $selection = Get-FairBatch $eligible $fileLimit $topicLimit $filesPerTopic $Config $context
    $selected = @($selection.items)
    return [ordered]@{
        status = if ($selected.Count -gt 0) { 'READY' } else { 'NO_PENDING' }
        count = $selected.Count
        topicCount = @($selection.topics).Count
        maxTopicsPerRun = $topicLimit
        remainingAfterBatch = [Math]::Max(0, $eligible.Count - $selected.Count)
        requiresConsentCount = $requiresConsent.Count
        requiresConsent = @($requiresConsent | Select-Object id, sourceId, sourceLabel, relativePath, modifiedUtc)
        excludedCount = $excludedNow.Count
        oversizedCount = $oversized.Count
        oversized = @($oversized | Select-Object id, sourceId, sourceLabel, relativePath, sizeBytes)
        topics = @($selection.topics)
        items = $selected
    }
}

function Resolve-ItemIds {
    # Accepts full 64-character queue IDs or unique prefixes of at least 8
    # characters, so humans no longer have to copy whole hashes around.
    param(
        [object[]]$Items,
        [string[]]$Ids
    )
    if ($Ids.Count -eq 0) {
        throw 'At least one ItemIds value is required.'
    }
    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $Ids) {
        $exact = @($Items | Where-Object { [string]$_.id -eq $id })
        if ($exact.Count -gt 0) {
            $resolved.Add([string]$exact[0].id)
            continue
        }
        if ($id.Length -lt 8) {
            throw "Queue ID prefix too short (need at least 8 characters): $id"
        }
        $byPrefix = @($Items | Where-Object { ([string]$_.id).StartsWith($id, [StringComparison]::OrdinalIgnoreCase) })
        if ($byPrefix.Count -eq 1) {
            $resolved.Add([string]$byPrefix[0].id)
        } elseif ($byPrefix.Count -eq 0) {
            throw "Unknown queue ID: $id"
        } else {
            throw "Ambiguous queue ID prefix: $id"
        }
    }
    return @($resolved | Select-Object -Unique)
}

function Invoke-Approve {
    param(
        [hashtable]$Paths,
        [string[]]$Ids
    )
    $queue = Get-Queue $Paths
    $resolved = @(Resolve-ItemIds @($queue.items) $Ids)
    foreach ($item in @($queue.items)) {
        if ($resolved -contains [string]$item.id) {
            Set-ObjectProperty $item 'consentStatus' 'approved'
        }
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        approved = $resolved.Count
        itemIds = @($resolved)
    }
}

function Invoke-Ack {
    param(
        [hashtable]$Paths,
        [string[]]$Ids
    )
    $queue = Get-Queue $Paths
    $resolved = @(Resolve-ItemIds @($queue.items) $Ids)
    $acknowledged = 0
    $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($queue.items)) {
        if ($resolved -contains [string]$item.id) {
            if (@('pending', 'missing') -contains [string]$item.status) {
                $item.status = 'processed'
                Set-ObjectProperty $item 'processedUtc' ([DateTime]::UtcNow.ToString('o'))
                Set-ObjectProperty $item 'error' $null
                $acknowledged++
            } else {
                $skipped.Add([PSCustomObject]@{ id = [string]$item.id; status = [string]$item.status })
            }
        }
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        acknowledged = $acknowledged
        skipped = @($skipped)
    }
}

function Invoke-Fail {
    # Retires items that can never be processed (corrupt, unsupported,
    # oversized) so they stop returning in every batch. Reversible via Requeue.
    param(
        [hashtable]$Paths,
        [string[]]$Ids,
        [string]$Reason
    )
    $reasonText = 'unspecified'
    if ($Reason) {
        $reasonText = $Reason
    }
    $queue = Get-Queue $Paths
    $resolved = @(Resolve-ItemIds @($queue.items) $Ids)
    $failed = 0
    $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($queue.items)) {
        if ($resolved -contains [string]$item.id) {
            if (@('pending', 'missing') -contains [string]$item.status) {
                $item.status = 'error'
                Set-ObjectProperty $item 'error' $reasonText
                $failed++
            } else {
                $skipped.Add([PSCustomObject]@{ id = [string]$item.id; status = [string]$item.status })
            }
        }
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        failed = $failed
        reason = $reasonText
        skipped = @($skipped)
    }
}

function Invoke-Requeue {
    param(
        [hashtable]$Paths,
        [string[]]$Ids
    )
    $queue = Get-Queue $Paths
    $resolved = @(Resolve-ItemIds @($queue.items) $Ids)
    $requeued = 0
    $skipped = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($queue.items)) {
        if ($resolved -contains [string]$item.id) {
            if ([string]$item.status -eq 'superseded') {
                # Resurrecting a superseded item would queue the same file
                # twice, next to its replacement version.
                $skipped.Add([PSCustomObject]@{ id = [string]$item.id; status = 'superseded' })
                continue
            }
            if (Test-Path -LiteralPath ([string]$item.fullPath) -PathType Leaf) {
                $item.status = 'pending'
            } else {
                $item.status = 'missing'
            }
            Set-ObjectProperty $item 'error' $null
            Set-ObjectProperty $item 'processedUtc' $null
            Set-ObjectProperty $item 'supersededBy' $null
            $requeued++
        }
    }
    Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($queue.items) })
    return [ordered]@{
        status = 'OK'
        requeued = $requeued
        skipped = @($skipped)
    }
}

function Invoke-Status {
    param(
        [hashtable]$Paths,
        [object]$Config
    )
    $context = New-ScanContext $Config
    $queue = Get-Queue $Paths
    $state = Get-State $Paths
    $counts = [ordered]@{}
    foreach ($statusName in @('pending', 'processed', 'superseded', 'missing', 'error')) {
        $counts[$statusName] = @($queue.items | Where-Object { [string]$_.status -eq $statusName }).Count
    }
    $counts['requiresConsent'] = @($queue.items | Where-Object {
        if ([string]$_.status -ne 'pending') { return $false }
        $consent = ''
        if (Test-HasProperty $_ 'consentStatus') { $consent = [string]$_.consentStatus }
        (Test-SensitivePath ([string]$_.relativePath) $context) -and $consent -ne 'approved'
    }).Count
    $counts['oversizedPending'] = @($queue.items | Where-Object {
        [string]$_.status -eq 'pending' -and [long]$_.sizeBytes -gt $context.maxBytes
    }).Count
    return [ordered]@{
        status = 'OK'
        counts = $counts
        sources = @($state.sources)
    }
}

function Invoke-Report {
    # Aggregates the queue into a per-source backlog overview and persists a
    # snapshot under the reports directory for run-over-run comparison.
    param(
        [hashtable]$Paths,
        [object]$Config
    )
    $context = New-ScanContext $Config
    $queue = Get-Queue $Paths
    $state = Get-State $Paths
    $now = [DateTime]::UtcNow

    $perSource = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($queue.items | Group-Object sourceId)) {
        $pendingItems = @($group.Group | Where-Object { [string]$_.status -eq 'pending' })
        $oldestUtc = $null
        $oldestAgeDays = $null
        if ($pendingItems.Count -gt 0) {
            $oldest = @($pendingItems | Sort-Object discoveredUtc)[0]
            $oldestUtc = [string]$oldest.discoveredUtc
            $oldestAgeDays = [Math]::Round(($now - [DateTime]::Parse($oldestUtc).ToUniversalTime()).TotalDays, 1)
        }
        $perSource.Add([PSCustomObject][ordered]@{
            sourceId = $group.Name
            pending = $pendingItems.Count
            missing = @($group.Group | Where-Object { [string]$_.status -eq 'missing' }).Count
            error = @($group.Group | Where-Object { [string]$_.status -eq 'error' }).Count
            requiresConsent = @($pendingItems | Where-Object {
                $consent = ''
                if (Test-HasProperty $_ 'consentStatus') { $consent = [string]$_.consentStatus }
                (Test-SensitivePath ([string]$_.relativePath) $context) -and $consent -ne 'approved'
            }).Count
            oversizedPending = @($pendingItems | Where-Object { [long]$_.sizeBytes -gt $context.maxBytes }).Count
            oldestPendingUtc = $oldestUtc
            oldestPendingAgeDays = $oldestAgeDays
        })
    }

    $totals = [ordered]@{}
    foreach ($statusName in @('pending', 'processed', 'superseded', 'missing', 'error')) {
        $totals[$statusName] = @($queue.items | Where-Object { [string]$_.status -eq $statusName }).Count
    }

    $report = [ordered]@{
        status = 'OK'
        generatedUtc = $now.ToString('o')
        totals = $totals
        sources = @($perSource)
        scanState = @($state.sources)
    }
    $reportPath = Join-Path $Paths.reports ('report-' + $now.ToString("yyyyMMdd'T'HHmmss'Z'") + '.json')
    Write-JsonAtomic $reportPath $report
    $report['reportPath'] = $reportPath
    return $report
}

function Invoke-Compact {
    # Moves old processed/superseded history into queue-archive.local.json so
    # the working queue stays small, and optionally prunes timestamped backup
    # sets older than the given number of days.
    param(
        [hashtable]$Paths,
        [int]$OlderThanDays,
        [int]$PruneBackupsOlderThanDays
    )
    if ($OlderThanDays -lt 0) {
        throw 'OlderThanDays must be zero or greater.'
    }
    $cutoff = [DateTime]::UtcNow.AddDays(-$OlderThanDays)
    $queue = Get-Queue $Paths
    $keep = [System.Collections.Generic.List[object]]::new()
    $archived = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($queue.items)) {
        $itemStatus = [string]$item.status
        if (@('processed', 'superseded') -contains $itemStatus) {
            $terminalUtc = [string]$item.discoveredUtc
            if ($itemStatus -eq 'processed' -and (Test-HasProperty $item 'processedUtc') -and $item.processedUtc) {
                $terminalUtc = [string]$item.processedUtc
            } elseif ($itemStatus -eq 'superseded' -and (Test-HasProperty $item 'supersededUtc') -and $item.supersededUtc) {
                # Items superseded by the pre-refactor version carry no
                # supersededUtc and fall back to discovery age.
                $terminalUtc = [string]$item.supersededUtc
            }
            if ([DateTime]::Parse($terminalUtc).ToUniversalTime() -lt $cutoff) {
                $archived.Add($item)
                continue
            }
        }
        $keep.Add($item)
    }
    if ($archived.Count -gt 0) {
        $existingArchive = Read-JsonFile $Paths.archive
        $archiveItems = [System.Collections.Generic.List[object]]::new()
        if ($existingArchive -and (Test-HasProperty $existingArchive 'items')) {
            foreach ($archivedItem in @($existingArchive.items)) {
                $archiveItems.Add($archivedItem)
            }
        }
        foreach ($archivedItem in $archived) {
            $archiveItems.Add($archivedItem)
        }
        Write-JsonAtomic $Paths.archive ([ordered]@{ schemaVersion = 1; items = @($archiveItems) })
        Write-JsonAtomic $Paths.queue ([ordered]@{ schemaVersion = 1; items = @($keep) })
    }

    $prunedBackups = 0
    if ($PruneBackupsOlderThanDays -gt 0) {
        $backupCutoff = [DateTime]::UtcNow.AddDays(-$PruneBackupsOlderThanDays)
        foreach ($base in @($Paths.backups, (Join-Path $Paths.backups 'metadata'))) {
            if (-not (Test-Path -LiteralPath $base -PathType Container)) {
                continue
            }
            foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory)) {
                $stamp = [DateTime]::MinValue
                $parsedOk = [DateTime]::TryParseExact(
                    $dir.Name,
                    "yyyyMMdd'T'HHmmss'Z'",
                    [Globalization.CultureInfo]::InvariantCulture,
                    ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),
                    [ref]$stamp)
                if (-not $parsedOk) {
                    continue
                }
                if ($stamp -ge $backupCutoff) {
                    continue
                }
                if (-not (Test-PathWithin $dir.FullName $Paths.backups)) {
                    continue
                }
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
                $prunedBackups++
            }
        }
    }

    return [ordered]@{
        status = 'OK'
        archived = $archived.Count
        remaining = $keep.Count
        prunedBackupSets = $prunedBackups
        archiveFile = $Paths.archive
    }
}

$script:BinaryExtensions = @(
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt', '.ods', '.odp',
    '.zip', '.7z', '.rar', '.gz', '.tar', '.epub', '.mobi',
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.tif', '.tiff', '.ico', '.heic', '.psd', '.ai',
    '.mp3', '.wav', '.flac', '.m4a', '.mp4', '.mov', '.avi', '.mkv', '.webm',
    '.exe', '.dll', '.so', '.dylib', '.ttf', '.otf', '.woff', '.woff2', '.db', '.sqlite'
)

function Get-InboxRoot {
    # The inbox is a vault-relative folder named by destinations.inbox. Rooted
    # or escaping values are rejected here rather than at write time so both
    # Inbox and InboxClear fail the same way on a bad config.
    param([object]$Config)
    if (-not (Test-HasProperty $Config 'destinations') -or
        -not (Test-HasProperty $Config.destinations 'inbox') -or
        -not $Config.destinations.inbox) {
        throw 'destinations.inbox is not configured; add it before using the Inbox commands.'
    }
    if (-not (Test-HasProperty $Config 'vaultRoot') -or -not $Config.vaultRoot) {
        throw 'vaultRoot is required.'
    }
    $relative = [string]$Config.destinations.inbox
    if ([IO.Path]::IsPathRooted($relative)) {
        throw "destinations.inbox must be relative to the vault: $relative"
    }
    $vault = Normalize-Path ([string]$Config.vaultRoot)
    $inbox = Normalize-Path (Join-Path $vault $relative)
    if (-not (Test-PathWithin $inbox $vault) -or $inbox.Equals($vault, [StringComparison]::OrdinalIgnoreCase)) {
        throw "destinations.inbox must resolve to a folder inside the vault: $relative"
    }
    return $inbox
}

function Get-InboxIndexNames {
    # Obsidian folder notes are named after their folder (00-Inbox/00-Inbox.md),
    # but vaults that number their folders usually drop the prefix inside them
    # (00-收件箱/收件箱.md, matching 04-工作项目/工作项目.md). Accept both, or the
    # note describing the inbox gets filed away as inbox content.
    param([string]$InboxRoot)
    $folder = [IO.Path]::GetFileName($InboxRoot)
    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add(($folder + '.md').ToLowerInvariant())
    $stripped = $folder -replace '^\d+[-_.\s]+', ''
    if ($stripped -and $stripped -ne $folder) {
        $names.Add(($stripped + '.md').ToLowerInvariant())
    }
    return ,$names.ToArray()
}

function Test-PlainTextFile {
    # Tells the caller whether an item can be read directly. Extension covers
    # the known container formats (a PDF has no NUL in its first bytes), and a
    # NUL sniff catches everything else, including extensionless drops.
    param([IO.FileInfo]$File)
    if ($script:BinaryExtensions -contains $File.Extension.ToLowerInvariant()) {
        return $false
    }
    if ($File.Length -le 0) {
        return $true
    }
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($File.FullName)
        $take = [int][Math]::Min(8192, $File.Length)
        $buffer = New-Object byte[] $take
        $read = $stream.Read($buffer, 0, $take)
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) {
                return $false
            }
        }
    } catch {
        return $false
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
    return $true
}

function Test-SensitiveInboxItem {
    # Inbox drops are deliberate, so nothing is filtered out; secret-like and
    # sensitive names are only flagged so the caller confirms before reading.
    param(
        [string]$RelativePath,
        [hashtable]$Context
    )
    $lowerPath = $RelativePath.ToLowerInvariant()
    $lowerName = ([IO.Path]::GetFileName($RelativePath)).ToLowerInvariant()
    if ($Context.ignoredFiles -contains $lowerName) {
        return $true
    }
    foreach ($fragment in $Context.ignoredFragments) {
        if ($lowerName.Contains($fragment)) {
            return $true
        }
    }
    foreach ($fragment in $Context.sensitiveFragments) {
        if ($lowerPath.Contains($fragment)) {
            return $true
        }
    }
    return $false
}

function Get-InboxEmptyDirectories {
    param([string]$InboxRoot)
    $empty = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $InboxRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            $empty.Add($dir.FullName.Substring($InboxRoot.Length).TrimStart('\', '/'))
        }
    }
    # Emitted as individual strings so callers can wrap with @() or pipe.
    return $empty.ToArray()
}

function Invoke-Inbox {
    # Lists everything waiting in the inbox so filing it is a real command
    # instead of an ad-hoc file search. Read-only: nothing is moved or opened
    # beyond the first bytes needed to classify text versus binary.
    param([object]$Config)

    $inboxRoot = Get-InboxRoot $Config
    $indexNames = Get-InboxIndexNames $inboxRoot
    if (-not (Test-Path -LiteralPath $inboxRoot -PathType Container)) {
        return [ordered]@{
            status = 'NOT_FOUND'
            inboxPath = $inboxRoot
            indexNote = @($indexNames)
            count = 0
            plainTextCount = 0
            inaccessibleDirectories = 0
            requiresReview = @()
            emptyDirectories = @()
            items = @()
        }
    }

    $context = New-ScanContext $Config
    $inaccessible = 0
    $files = Get-CandidateFiles -Root $inboxRoot -IgnoredDirectoryNames @() -InaccessibleCount ([ref]$inaccessible)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($inboxRoot.Length).TrimStart('\', '/')
        if ($indexNames -contains $relative.ToLowerInvariant()) {
            continue
        }
        $items.Add([PSCustomObject][ordered]@{
            relativePath = $relative
            kind = 'file'
            extension = $file.Extension.ToLowerInvariant()
            sizeBytes = $file.Length
            modifiedUtc = $file.LastWriteTimeUtc.ToString('o')
            isPlainText = (Test-PlainTextFile $file)
            sensitive = (Test-SensitiveInboxItem $relative $context)
            fullPath = $file.FullName
        })
    }
    $ordered = @($items | Sort-Object modifiedUtc, relativePath)

    return [ordered]@{
        status = 'OK'
        inboxPath = $inboxRoot
        indexNote = @($indexNames)
        count = $ordered.Count
        plainTextCount = @($ordered | Where-Object { $_.isPlainText }).Count
        inaccessibleDirectories = $inaccessible
        requiresReview = @($ordered | Where-Object { $_.sensitive } | Select-Object relativePath, sizeBytes)
        emptyDirectories = @(Get-InboxEmptyDirectories $inboxRoot)
        items = $ordered
    }
}

function Move-InboxEntry {
    param(
        [string]$From,
        [string]$To,
        [string]$Kind
    )
    if ($Kind -eq 'file') {
        [IO.File]::Move($From, $To)
        return
    }
    try {
        [IO.Directory]::Move($From, $To)
    } catch [IO.IOException] {
        # Directory.Move cannot cross volumes, and a vault on a different drive
        # than controllerDataRoot is a normal setup. Copy first, delete after.
        Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
        Remove-Item -LiteralPath $From -Recurse -Force
    }
}

function Invoke-InboxClear {
    # Filed items leave the inbox by moving into a timestamped archive under
    # controllerDataRoot, never by deletion: if a distillation later turns out
    # wrong, the original drop is still on disk.
    param(
        [object]$Config,
        [hashtable]$Paths,
        [string[]]$Ids
    )
    if ($Ids.Count -eq 0) {
        throw 'At least one ItemIds value is required.'
    }
    $inboxRoot = Get-InboxRoot $Config
    if (-not (Test-Path -LiteralPath $inboxRoot -PathType Container)) {
        throw "Inbox folder not found: $inboxRoot"
    }
    $indexNames = Get-InboxIndexNames $inboxRoot

    # Resolve every id before moving anything, so a typo in the last id cannot
    # leave the inbox half-cleared.
    $planned = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($id in $Ids) {
        $trimmed = ([string]$id).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            throw 'Inbox item path must not be empty.'
        }
        if ([IO.Path]::IsPathRooted($trimmed)) {
            throw "Inbox item must be a path relative to the inbox folder: $id"
        }
        $candidate = Normalize-Path (Join-Path $inboxRoot $trimmed)
        if (-not (Test-PathWithin $candidate $inboxRoot) -or $candidate.Equals($inboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Inbox item is outside the inbox folder: $id"
        }
        $relative = $candidate.Substring($inboxRoot.Length).TrimStart('\', '/')
        if ($indexNames -contains $relative.ToLowerInvariant()) {
            throw "Refusing to move the inbox index note: $relative"
        }
        $kind = ''
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $kind = 'file'
        } elseif (Test-Path -LiteralPath $candidate -PathType Container) {
            $kind = 'directory'
        } else {
            throw "Unknown inbox item: $id"
        }
        $key = $relative.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $planned.Add([PSCustomObject]@{
            relativePath = $relative
            fullPath = $candidate
            kind = $kind
        })
    }

    # Clearing a folder and something inside it in one call would move the
    # parent first and then fail on a child that no longer exists, leaving the
    # inbox half-cleared. Reject the overlap up front instead.
    foreach ($outer in $planned) {
        foreach ($inner in $planned) {
            if ([string]$outer.fullPath -eq [string]$inner.fullPath) {
                continue
            }
            if (Test-PathWithin ([string]$inner.fullPath) ([string]$outer.fullPath)) {
                throw "Inbox items overlap; clear the folder or its contents, not both: $($outer.relativePath) | $($inner.relativePath)"
            }
        }
    }

    # Folders that were already empty before this run were not emptied by it,
    # so they stay: this command only ever touches what it was asked to file.
    $preExistingEmpty = @{}
    foreach ($relativeDir in @(Get-InboxEmptyDirectories $inboxRoot)) {
        $preExistingEmpty[$relativeDir.ToLowerInvariant()] = $true
    }

    $archiveRoot = Join-Path $Paths.inboxArchive ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'"))
    $moved = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $planned) {
        $target = Join-Path $archiveRoot ([string]$entry.relativePath)
        if (Test-Path -LiteralPath $target) {
            throw "Archive target already exists: $target"
        }
        $targetParent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }
        Move-InboxEntry ([string]$entry.fullPath) $target ([string]$entry.kind)
        $moved.Add([PSCustomObject][ordered]@{
            relativePath = [string]$entry.relativePath
            kind = [string]$entry.kind
            from = [string]$entry.fullPath
            to = $target
        })
    }

    # Folders emptied by the move carry no data; leaving them behind would make
    # a cleared inbox still look occupied.
    # Repeat until stable so a parent that only held the folder just removed is
    # cleaned in the same run.
    $pruned = [System.Collections.Generic.List[string]]::new()
    for ($pass = 0; $pass -lt 32; $pass++) {
        $removedThisPass = 0
        foreach ($relativeDir in @(Get-InboxEmptyDirectories $inboxRoot | Sort-Object -Property Length -Descending)) {
            if ($preExistingEmpty.ContainsKey($relativeDir.ToLowerInvariant())) {
                continue
            }
            $directory = Join-Path $inboxRoot $relativeDir
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                continue
            }
            if (-not (Test-PathWithin $directory $inboxRoot) -or (Normalize-Path $directory).Equals($inboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            Remove-Item -LiteralPath $directory -Force
            $pruned.Add($relativeDir)
            $removedThisPass++
        }
        if ($removedThisPass -eq 0) {
            break
        }
    }

    $after = Invoke-Inbox $Config
    return [ordered]@{
        status = 'OK'
        inboxPath = $inboxRoot
        archiveRoot = $archiveRoot
        movedCount = $moved.Count
        moved = @($moved)
        prunedDirectories = @($pruned)
        remaining = $after['count']
    }
}

function Invoke-NewConfig {
    # One-command onboarding: copies the shipped example config so a new user
    # never has to hunt for the right JSON shape. Never overwrites.
    param([string]$TargetPath)
    if (-not $TargetPath) {
        $TargetPath = Join-Path (Get-Location).Path 'config.local.json'
    }
    $target = [IO.Path]::GetFullPath($TargetPath)
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        throw "Refusing to overwrite existing config: $target"
    }
    $example = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\config.example.json'
    if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
        throw "Example config not found: $example"
    }
    $content = Get-Content -LiteralPath $example -Raw -Encoding UTF8
    Write-TextAtomic -Path $target -Content $content
    return [ordered]@{
        status = 'OK'
        configPath = $target
        nextSteps = @(
            'Edit vaultRoot, controllerDataRoot, and semanticSources with your real paths.',
            'Every semanticSources path must be a folder you explicitly approve for content reading.',
            'Run Doctor with this ConfigPath and fix every error and warning.',
            'Then run Init, Scan, and one manual Next batch before scheduling weekly runs.'
        )
    }
}

function Invoke-Discover {
    param([object]$Config)
    $discovery = $null
    if (Test-HasProperty $Config 'discovery') {
        $discovery = $Config.discovery
    }
    if (-not $discovery -or -not (Test-HasProperty $discovery 'consentGranted') -or $discovery.consentGranted -ne $true) {
        throw 'Discovery requires explicit consent: discovery.consentGranted must be true.'
    }
    $context = New-ScanContext $Config
    $results = [System.Collections.Generic.List[object]]::new()
    $discoveryRoots = @()
    if (Test-HasProperty $discovery 'roots') {
        $discoveryRoots = @($discovery.roots)
    }
    foreach ($rootEntry in $discoveryRoots) {
        $root = Normalize-Path ([string]$rootEntry)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            $results.Add([PSCustomObject]@{ root = $root; status = 'NOT_FOUND' })
            continue
        }
        $inaccessible = 0
        $files = Get-CandidateFiles -Root $root -IgnoredDirectoryNames $context.ignoredDirs -InaccessibleCount ([ref]$inaccessible)
        $topGroups = @($files | ForEach-Object {
            $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $segments = @($relative -split '[\\/]')
            if ($segments.Count -gt 1) { $segments[0] } else { '[root]' }
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
            inaccessibleDirectories = $inaccessible
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

if ($Command -eq 'NewConfig') {
    Invoke-NewConfig $TargetPath | ConvertTo-Json -Depth 12
    return
}

if (-not $ConfigPath) {
    throw "ConfigPath is required for the $Command command."
}
$config = Get-Config
$paths = Get-DataPaths $config

$result = switch ($Command) {
    'Doctor' { Invoke-Doctor $config }
    'Init' {
        Assert-Doctor $config
        foreach ($directory in @($paths.root, $paths.backups, $paths.reports)) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
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
    'Fail' { Invoke-Fail $paths $ItemIds $Reason }
    'Requeue' { Invoke-Requeue $paths $ItemIds }
    'Status' { Invoke-Status $paths $config }
    'Report' { Invoke-Report $paths $config }
    'Compact' { Invoke-Compact $paths $OlderThanDays $PruneBackupsOlderThanDays }
    'Discover' { Invoke-Discover $config }
    'Inbox' { Invoke-Inbox $config }
    'InboxClear' { Invoke-InboxClear $config $paths $ItemIds }
}

$result | ConvertTo-Json -Depth 12
