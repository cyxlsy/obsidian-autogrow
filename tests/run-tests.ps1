param(
    [string]$SkillRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\grow-obsidian')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Invoke-JsonCommand {
    param([string]$Tool, [hashtable]$Parameters)
    $text = (& $Tool @Parameters | Out-String).Trim()
    return $text | ConvertFrom-Json
}

function Normalize-Path {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-PathWithin {
    param([string]$Candidate, [string]$Parent)
    $candidatePath = Normalize-Path $Candidate
    $parentPath = Normalize-Path $Parent
    return $candidatePath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('grow-obsidian-test-' + [Guid]::NewGuid().ToString('N'))
$resolvedTempRoot = Normalize-Path ([IO.Path]::GetTempPath())

try {
    $sourceA = Join-Path $testRoot 'source-a'
    $sourceB = Join-Path $testRoot 'source-b'
    $sourceMetadata = Join-Path $testRoot 'metadata-source'
    $vault = Join-Path $testRoot 'vault'
    $data = Join-Path $testRoot 'private-data'
    foreach ($path in @($sourceA, $sourceB, $sourceMetadata, $vault, $data)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    [IO.File]::WriteAllText((Join-Path $sourceA 'alpha-final.md'), 'alpha', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceA 'alpha-notes.txt'), 'notes', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceA 'private-chat-log.md'), 'sensitive', [Text.UTF8Encoding]::new($false))
    $nodeModules = Join-Path $sourceA 'node_modules\dep'
    New-Item -ItemType Directory -Path $nodeModules -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $nodeModules 'dep.md'), 'dependency readme', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceB 'beta-report.md'), 'beta', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceB 'beta-code.py'), 'print(1)', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceB 'big-report.md'), ('x' * 5000), [Text.UTF8Encoding]::new($false))
    $metadataProject = Join-Path $sourceMetadata 'wrapper\account\cloud\客户项目'
    New-Item -ItemType Directory -Path $metadataProject -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $metadataProject 'test.docx'), 'secret-content-must-not-appear', [Text.UTF8Encoding]::new($false))
    $metadataCache = Join-Path $sourceMetadata 'wrapper\cache'
    New-Item -ItemType Directory -Path $metadataCache -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $metadataCache 'cached.docx'), 'cache noise', [Text.UTF8Encoding]::new($false))

    $configPath = Join-Path $testRoot 'config.local.json'
    $config = [ordered]@{
        schemaVersion = 1
        vaultRoot = $vault
        controllerDataRoot = $data
        semanticSources = @(
            [ordered]@{ id = 'a'; label = 'A'; path = $sourceA },
            [ordered]@{ id = 'b'; label = 'B'; path = $sourceB }
        )
        metadataOnlySources = @(
            [ordered]@{
                id = 'catalog'
                label = 'Catalog'
                path = $sourceMetadata
                destination = '04-Work\Catalog.md'
                readFileContents = $false
                title = 'Catalog'
                stripPrefixSegments = 3
                groupDepth = 1
            }
        )
        destinations = [ordered]@{ home = '00-Home'; inbox = '00-Inbox'; workProjects = '04-Work' }
        scanPolicy = [ordered]@{
            stableMinutes = 0
            initialLookbackDays = 10
            maxFilesPerBatch = 2
            maxTopicsPerRun = 2
            maxSemanticFileBytes = 4096
            allowedExtensions = @('.md', '.txt', '.py')
            highValueExtensions = @('.md')
            highValueNameFragments = @('final', 'report')
        }
        privacy = [ordered]@{
            ignoredDirectories = @('.git', 'node_modules')
            ignoredFileNames = @('.env')
            ignoredNameFragments = @('token', 'secret')
            sensitiveNameFragments = @('private-chat')
            excludedPaths = @()
        }
        discovery = [ordered]@{ consentGranted = $false; roots = @() }
        features = [ordered]@{
            creatorInsights = [ordered]@{
                enabled = $false
                focusAreas = @()
                input = 'distilled-notes-only'
            }
        }
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    $tool = Join-Path $SkillRoot 'scripts\grow-obsidian.ps1'
    $applyTool = Join-Path $SkillRoot 'scripts\apply-note.ps1'
    $catalogTool = Join-Path $SkillRoot 'scripts\catalog-metadata.ps1'

    # --- Doctor ---
    $doctor = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Doctor'; ConfigPath = $configPath }
    Assert-True ($doctor.status -eq 'OK') 'Doctor should pass for isolated paths.'
    Assert-True (@($doctor.warnings).Count -eq 0) 'Doctor should produce no warnings for a clean config.'

    # --- Doctor: unknown-key warnings (typo protection) ---
    $typoConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Member -InputObject $typoConfig -NotePropertyName 'extraKey' -NotePropertyValue 1 -Force
    Add-Member -InputObject $typoConfig.scanPolicy -NotePropertyName 'maxFilesPerBatchh' -NotePropertyValue 5 -Force
    Add-Member -InputObject $typoConfig.features -NotePropertyName 'creatorInsight' -NotePropertyValue 1 -Force
    $typoConfigPath = Join-Path $testRoot 'config-typo.json'
    [IO.File]::WriteAllText($typoConfigPath, ($typoConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $typoDoctor = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Doctor'; ConfigPath = $typoConfigPath }
    Assert-True (@($typoDoctor.warnings | Where-Object { $_ -like '*extraKey*' }).Count -eq 1) 'Doctor must warn about unknown root keys.'
    Assert-True (@($typoDoctor.warnings | Where-Object { $_ -like '*maxFilesPerBatchh*' }).Count -eq 1) 'Doctor must warn about misspelled scanPolicy keys.'
    Assert-True (@($typoDoctor.warnings | Where-Object { $_ -like '*creatorInsight*' }).Count -eq 1) 'Doctor must warn about misspelled features keys.'

    # --- Doctor: invalid values and unsafe layouts are errors ---
    $invalidConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Member -InputObject $invalidConfig.scanPolicy -NotePropertyName 'maxFilesPerTopic' -NotePropertyValue 0 -Force
    $invalidMetadata = @($invalidConfig.metadataOnlySources)[0]
    $invalidMetadata.destination = 'D:\evil-out.md'
    $invalidMetadata.path = $sourceA
    $invalidConfigPath = Join-Path $testRoot 'config-invalid.json'
    [IO.File]::WriteAllText($invalidConfigPath, ($invalidConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $invalidDoctor = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Doctor'; ConfigPath = $invalidConfigPath }
    Assert-True ($invalidDoctor.status -eq 'ERROR') 'Invalid config values must fail Doctor.'
    Assert-True (@($invalidDoctor.errors | Where-Object { $_ -like '*maxFilesPerTopic*' }).Count -eq 1) 'maxFilesPerTopic below one must be an error.'
    Assert-True (@($invalidDoctor.errors | Where-Object { $_ -like '*relative to the vault*' }).Count -eq 1) 'Absolute metadata destinations must be rejected.'
    Assert-True (@($invalidDoctor.errors | Where-Object { $_ -like '*overlaps a semantic source*' }).Count -ge 1) 'Metadata roots overlapping semantic roots must be rejected.'

    # --- NewConfig onboarding ---
    $newConfigTarget = Join-Path $testRoot 'fresh\config.local.json'
    $newConfig = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'NewConfig'; TargetPath = $newConfigTarget }
    Assert-True ($newConfig.status -eq 'OK') 'NewConfig must create a starter config.'
    Assert-True (Test-Path -LiteralPath $newConfigTarget -PathType Leaf) 'NewConfig must write the target file.'
    $starter = Get-Content -LiteralPath $newConfigTarget -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([int]$starter.schemaVersion -eq 1) 'Starter config must parse as JSON.'
    $overwriteThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'NewConfig'; TargetPath = $newConfigTarget }
    } catch {
        $overwriteThrown = $_.Exception.Message.Contains('Refusing to overwrite')
    }
    Assert-True $overwriteThrown 'NewConfig must never overwrite an existing config.'

    # --- Example config validates against the JSON schema (pwsh only) ---
    $schemaPath = Join-Path $SkillRoot 'assets\config.schema.json'
    if ((Get-Command Test-Json -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        $exampleJson = Get-Content -LiteralPath (Join-Path $SkillRoot 'assets\config.example.json') -Raw -Encoding UTF8
        $schemaJson = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8
        Assert-True (Test-Json -Json $exampleJson -Schema $schemaJson) 'config.example.json must validate against config.schema.json.'
    }

    # --- Init and metadata catalog ---
    $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Init'; ConfigPath = $configPath }
    $catalog = Invoke-JsonCommand -Tool $catalogTool -Parameters @{ ConfigPath = $configPath }
    Assert-True ($catalog.contentRead -eq $false) 'Metadata catalog must report contentRead=false.'
    $catalogText = Get-Content -LiteralPath (Join-Path $vault '04-Work\Catalog.md') -Raw -Encoding UTF8
    Assert-True ($catalogText.Contains('test.docx')) 'Metadata catalog must include the filename.'
    Assert-True ($catalogText.Contains('客户项目')) 'Metadata grouping must strip wrapper segments.'
    Assert-True (-not $catalogText.Contains('secret-content-must-not-appear')) 'Metadata catalog must not copy file content.'
    Assert-True (-not $catalogText.Contains('cached.docx')) 'Metadata catalog must prune ignored directories.'

    # --- Catalog: refuses to overwrite a human-authored destination ---
    $catalogDestination = Join-Path $vault '04-Work\Catalog.md'
    [IO.File]::WriteAllText($catalogDestination, '人工笔记内容', [Text.UTF8Encoding]::new($false))
    $catalogRefuse = Invoke-JsonCommand -Tool $catalogTool -Parameters @{ ConfigPath = $configPath }
    $refuseEntry = @($catalogRefuse.sources | Where-Object { $_.id -eq 'catalog' })[0]
    Assert-True ($refuseEntry.status -eq 'SKIPPED_HUMAN_FILE') 'Catalog must refuse files without the generator sentinel.'
    $refusedText = Get-Content -LiteralPath $catalogDestination -Raw -Encoding UTF8
    Assert-True ($refusedText.Contains('人工笔记内容')) 'Human-authored destination content must be preserved.'

    # --- Catalog: tolerates configs without a metadataOnlySources section ---
    $noMetaConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $noMetaConfig.PSObject.Properties.Remove('metadataOnlySources')
    $noMetaConfigPath = Join-Path $testRoot 'config-nometa.json'
    [IO.File]::WriteAllText($noMetaConfigPath, ($noMetaConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $noMetaCatalog = Invoke-JsonCommand -Tool $catalogTool -Parameters @{ ConfigPath = $noMetaConfigPath }
    Assert-True ($noMetaCatalog.status -eq 'OK') 'Catalog must handle configs without metadataOnlySources.'

    # --- Scan: lossless queue, directory pruning, consent quarantine ---
    $scan = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Scan'; ConfigPath = $configPath }
    Assert-True ($scan.enqueued -eq 6) 'First scan should enqueue six files (node_modules pruned).'
    Assert-True ($scan.pending -eq 6) 'No queued file may be lost behind batch caps.'
    Assert-True ($scan.requiresConsent -eq 1) 'Sensitive filename must be quarantined for consent.'

    # --- Next: fairness, consent exclusion, oversized exclusion ---
    $next = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Next'; ConfigPath = $configPath }
    Assert-True ($next.count -eq 2) 'Next must respect maxFilesPerBatch.'
    $sourceCount = @($next.items.sourceId | Sort-Object -Unique).Count
    Assert-True ($sourceCount -eq 2) 'Fair batch should include both sources.'
    Assert-True ($next.requiresConsentCount -eq 1) 'Next must surface consent-required candidates.'
    Assert-True (@($next.items | Where-Object { $_.relativePath -eq 'private-chat-log.md' }).Count -eq 0) 'Sensitive items must not enter the batch without approval.'
    Assert-True ($next.oversizedCount -eq 1) 'Next must surface oversized candidates.'
    Assert-True (@($next.items | Where-Object { $_.relativePath -eq 'big-report.md' }).Count -eq 0) 'Oversized items must not enter the batch.'

    # --- Approve via short ID prefix ---
    $sensitiveId = [string]$next.requiresConsent[0].id
    $null = & $tool -Command Approve -ConfigPath $configPath -ItemIds @($sensitiveId.Substring(0, 12)) | Out-String
    $nextAfterApprove = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Next'; ConfigPath = $configPath }
    Assert-True ($nextAfterApprove.requiresConsentCount -eq 0) 'Approved sensitive items must leave the consent list.'

    # --- Ack via short ID prefixes ---
    $ackPrefixes = @($next.items | ForEach-Object { ([string]$_.id).Substring(0, 12) })
    $ack = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Ack'; ConfigPath = $configPath; ItemIds = $ackPrefixes }
    Assert-True ($ack.acknowledged -eq 2) 'Ack should process only selected items.'
    $status = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Status'; ConfigPath = $configPath }
    Assert-True ($status.counts.processed -eq 2) 'Ack should mark exactly the selected items processed.'
    Assert-True ($status.counts.pending -eq 4) 'Unselected items must remain pending.'
    Assert-True ($status.counts.oversizedPending -eq 1) 'Status must count oversized pending items.'

    # --- apply-note: template, marker-bounded update, backup ---
    $noteRelative = '04-Work\Example.md'
    $block1 = Join-Path $testRoot 'block1.md'
    [IO.File]::WriteAllText($block1, '## 本轮成果' + [Environment]::NewLine + '第一版', [Text.UTF8Encoding]::new($false))
    $newNoteTemplate = Join-Path $testRoot 'new-note-template.md'
    [IO.File]::WriteAllText($newNoteTemplate, '# 人工标题' + [Environment]::NewLine + [Environment]::NewLine + '{{AI_BLOCK}}', [Text.UTF8Encoding]::new($false))
    $firstApply = Invoke-JsonCommand -Tool $applyTool -Parameters @{
        ConfigPath = $configPath
        RelativeNotePath = $noteRelative
        GeneratedBlockPath = $block1
        NewNoteTemplatePath = $newNoteTemplate
    }
    Assert-True ($firstApply.status -eq 'OK') 'Initial note apply should succeed.'

    $notePath = Join-Path $vault $noteRelative
    $firstText = Get-Content -LiteralPath $notePath -Raw -Encoding UTF8
    [IO.File]::WriteAllText($notePath, $firstText + [Environment]::NewLine + '人工补充', [Text.UTF8Encoding]::new($false))
    $currentHash = (Get-FileHash -LiteralPath $notePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $block2 = Join-Path $testRoot 'block2.md'
    [IO.File]::WriteAllText($block2, '## 本轮成果' + [Environment]::NewLine + '第二版', [Text.UTF8Encoding]::new($false))
    $secondApply = Invoke-JsonCommand -Tool $applyTool -Parameters @{
        ConfigPath = $configPath
        RelativeNotePath = $noteRelative
        GeneratedBlockPath = $block2
        ExpectedCurrentHash = $currentHash
    }
    Assert-True ($secondApply.status -eq 'OK') 'Marker update should succeed with matching hash.'
    $secondText = Get-Content -LiteralPath $notePath -Raw -Encoding UTF8
    Assert-True ($secondText.Contains('# 人工标题')) 'New-note template must be used.'
    Assert-True ($secondText.Contains('人工补充')) 'Human-authored text must be preserved.'
    Assert-True ($secondText.Contains('第二版')) 'Generated block must be updated.'
    Assert-True (-not $secondText.Contains('第一版')) 'Old generated block must be replaced.'
    Assert-True ([bool]$secondApply.backupPath) 'Updating an existing note must create a backup.'

    # --- apply-note: conflict detection ---
    $conflictThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $applyTool -Parameters @{
            ConfigPath = $configPath
            RelativeNotePath = $noteRelative
            GeneratedBlockPath = $block2
            ExpectedCurrentHash = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        }
    } catch {
        $conflictThrown = $_.Exception.Message.Contains('Conflict')
    }
    Assert-True $conflictThrown 'A stale expected hash must be rejected.'

    # --- apply-note: incomplete markers refuse to write ---
    $brokenRelative = '04-Work\Broken.md'
    $brokenPath = Join-Path $vault $brokenRelative
    [IO.File]::WriteAllText($brokenPath, '<!-- AI-MAINTAINED:START -->' + [Environment]::NewLine + 'orphan', [Text.UTF8Encoding]::new($false))
    $incompleteThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $applyTool -Parameters @{
            ConfigPath = $configPath
            RelativeNotePath = $brokenRelative
            GeneratedBlockPath = $block2
        }
    } catch {
        $incompleteThrown = $_.Exception.Message.Contains('incomplete')
    }
    Assert-True $incompleteThrown 'Incomplete markers must refuse modification.'

    # --- Scan: newer version supersedes older pending version ---
    $alphaNotes = Join-Path $sourceA 'alpha-notes.txt'
    [IO.File]::WriteAllText($alphaNotes, 'notes version two with more content', [Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $alphaNotes).LastWriteTimeUtc = [DateTime]::UtcNow
    $scan2 = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Scan'; ConfigPath = $configPath }
    Assert-True ($scan2.superseded -eq 1) 'A newer file version must supersede the older pending version.'
    Assert-True ($scan2.enqueued -eq 1) 'Only the changed file should be enqueued on rescan.'

    # --- Superseded items carry supersededUtc and resist Requeue ---
    $queueSuperseded = Get-Content -LiteralPath (Join-Path $data 'queue.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $supersededItem = @($queueSuperseded.items | Where-Object { $_.status -eq 'superseded' })[0]
    Assert-True ([bool]$supersededItem.supersededUtc) 'Supersede must stamp supersededUtc for later aging.'
    $requeueSuperseded = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Requeue'; ConfigPath = $configPath; ItemIds = @(([string]$supersededItem.id).Substring(0, 12)) }
    Assert-True ($requeueSuperseded.requeued -eq 0) 'Requeue must refuse superseded items to avoid duplicate queue entries.'

    # --- Scan: deleted files are swept to missing ---
    Remove-Item -LiteralPath (Join-Path $sourceB 'beta-code.py') -Force
    $scan3 = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Scan'; ConfigPath = $configPath }
    Assert-True ($scan3.missingMarked -eq 1) 'Deleted files must be marked missing instead of staying pending.'
    $statusAfterMissing = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Status'; ConfigPath = $configPath }
    Assert-True ($statusAfterMissing.counts.missing -eq 1) 'Status must count missing items.'

    # --- Junctions are pruned during scan (cycle safety) ---
    $junctionTarget = Join-Path $testRoot 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $junctionTarget 'loop-file.md'), 'loop', [Text.UTF8Encoding]::new($false))
    $junctionPath = Join-Path $sourceA 'loop'
    $null = cmd /c ('mklink /J "' + $junctionPath + '" "' + $junctionTarget + '" >nul 2>&1')
    if (Test-Path -LiteralPath $junctionPath) {
        $scanJunction = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Scan'; ConfigPath = $configPath }
        Assert-True ($scanJunction.enqueued -eq 0) 'Files behind junctions must not be enqueued.'
        $null = cmd /c ('rmdir "' + $junctionPath + '"')
    }

    # --- Fail and Requeue ---
    $queueJson = Get-Content -LiteralPath (Join-Path $data 'queue.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $bigItem = @($queueJson.items | Where-Object { $_.relativePath -eq 'big-report.md' })[0]
    $bigPrefix = ([string]$bigItem.id).Substring(0, 12)
    $fail = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Fail'; ConfigPath = $configPath; ItemIds = @($bigPrefix); Reason = 'oversized beyond read budget' }
    Assert-True ($fail.failed -eq 1) 'Fail must retire unprocessable items.'
    $statusAfterFail = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Status'; ConfigPath = $configPath }
    Assert-True ($statusAfterFail.counts.error -eq 1) 'Failed items must be counted as error.'
    $requeue = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Requeue'; ConfigPath = $configPath; ItemIds = @($bigPrefix) }
    Assert-True ($requeue.requeued -eq 1) 'Requeue must restore retired items.'
    $statusAfterRequeue = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Status'; ConfigPath = $configPath }
    Assert-True ($statusAfterRequeue.counts.error -eq 0) 'Requeued items must leave the error state.'

    # --- Compact: superseded items age by supersede time, not discovery time ---
    $backdateQueue = Get-Content -LiteralPath (Join-Path $data 'queue.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($backdateItem in @($backdateQueue.items)) {
        if ($backdateItem.status -eq 'superseded') {
            $backdateItem.discoveredUtc = '2000-01-01T00:00:00.0000000Z'
        }
    }
    [IO.File]::WriteAllText((Join-Path $data 'queue.local.json'), ($backdateQueue | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $compactFresh = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Compact'; ConfigPath = $configPath; OlderThanDays = 30 }
    Assert-True ($compactFresh.archived -eq 0) 'A freshly superseded item must not be archived by a 30-day compact, even if discovered long ago.'

    # --- Compact: archive terminal history, prune old backups only ---
    $compact = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Compact'; ConfigPath = $configPath; OlderThanDays = 0 }
    Assert-True ($compact.archived -eq 3) 'Compact must archive processed and superseded history.'
    $queueAfterCompact = Get-Content -LiteralPath (Join-Path $data 'queue.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($queueAfterCompact.items).Count -eq 4) 'Compact must keep active items in the queue.'
    $archiveJson = Get-Content -LiteralPath (Join-Path $data 'queue-archive.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($archiveJson.items).Count -eq 3) 'Archived items must land in the archive file.'

    $oldBackup = Join-Path $data 'backups\19990101T000000Z'
    New-Item -ItemType Directory -Path $oldBackup -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldBackup 'old.md'), 'old backup', [Text.UTF8Encoding]::new($false))
    $compact2 = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Compact'; ConfigPath = $configPath; OlderThanDays = 9999; PruneBackupsOlderThanDays = 30 }
    Assert-True ($compact2.prunedBackupSets -ge 1) 'Old backup sets must be pruned on request.'
    Assert-True (-not (Test-Path -LiteralPath $oldBackup)) 'The stale backup set must be removed.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $data 'backups') -Directory).Count -ge 1) 'Recent backup sets must survive pruning.'

    # --- Retroactive excludedPaths: queued items under a newly excluded path stay out of batches ---
    $exclConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $exclConfig.privacy.excludedPaths = @($sourceB)
    $exclConfigPath = Join-Path $testRoot 'config-excl.json'
    [IO.File]::WriteAllText($exclConfigPath, ($exclConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $exclNext = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Next'; ConfigPath = $exclConfigPath }
    Assert-True ($exclNext.excludedCount -ge 1) 'Newly excluded paths must retroactively quarantine queued items.'
    Assert-True (@($exclNext.items | Where-Object { $_.sourceId -eq 'b' }).Count -eq 0) 'No excluded-path item may enter a batch.'

    # --- Discover: consent gate ---
    $discoverThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Discover'; ConfigPath = $configPath }
    } catch {
        $discoverThrown = $_.Exception.Message.Contains('consent')
    }
    Assert-True $discoverThrown 'Discovery must refuse to run without explicit consent.'

    # --- Discover: consented config without a roots key returns empty, not a crash ---
    $discoverConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $discoverConfig.discovery.consentGranted = $true
    $discoverConfig.discovery.PSObject.Properties.Remove('roots')
    $discoverConfigPath = Join-Path $testRoot 'config-discover.json'
    [IO.File]::WriteAllText($discoverConfigPath, ($discoverConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $discoverEmpty = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Discover'; ConfigPath = $discoverConfigPath }
    Assert-True ($discoverEmpty.status -eq 'OK' -and @($discoverEmpty.roots).Count -eq 0) 'Discover must tolerate a missing roots key.'

    # --- Report ---
    $report = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Report'; ConfigPath = $configPath }
    Assert-True ($report.status -eq 'OK') 'Report must succeed.'
    Assert-True ($report.totals.pending -eq 3) 'Report totals must match queue state.'
    Assert-True (Test-Path -LiteralPath ([string]$report.reportPath) -PathType Leaf) 'Report must persist a snapshot file.'

    # --- Fairness: oldest backlog is served first, not alphabetical order ---
    $queueEdit = Get-Content -LiteralPath (Join-Path $data 'queue.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($queueItem in @($queueEdit.items)) {
        if ($queueItem.sourceId -eq 'b' -and $queueItem.status -eq 'pending') {
            $queueItem.discoveredUtc = '2000-01-01T00:00:00.0000000Z'
        }
    }
    [IO.File]::WriteAllText((Join-Path $data 'queue.local.json'), ($queueEdit | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $fairConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $fairConfig.scanPolicy.maxTopicsPerRun = 1
    $fairConfig.scanPolicy.maxFilesPerBatch = 1
    $fairConfig.scanPolicy.maxSemanticFileBytes = 10485760
    $fairConfigPath = Join-Path $testRoot 'config-fair.json'
    [IO.File]::WriteAllText($fairConfigPath, ($fairConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $fairNext = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Next'; ConfigPath = $fairConfigPath }
    Assert-True (@($fairNext.topics)[0].sourceId -eq 'b') 'The source with the oldest backlog must be served first, regardless of alphabetical order.'

    # --- Inbox: listing excludes the folder index note ---
    $inboxFolder = Join-Path $vault '00-Inbox'
    $inboxNested = Join-Path $inboxFolder 'clip'
    $inboxKeepEmpty = Join-Path $inboxFolder 'keep-empty'
    foreach ($path in @($inboxFolder, $inboxNested, $inboxKeepEmpty)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $inboxFolder '00-Inbox.md'), '# 收件箱索引', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $inboxFolder '随手记.md'), '一个零碎想法', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $inboxFolder 'snippet.txt'), 'plain text drop', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $inboxNested 'nested-note.md'), 'nested drop', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $inboxFolder 'photo.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02))

    $inbox = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Inbox'; ConfigPath = $configPath }
    Assert-True ($inbox.status -eq 'OK') 'Inbox must list a configured inbox folder.'
    Assert-True ($inbox.count -eq 4) 'Inbox must list every dropped item, including nested ones.'
    Assert-True (@($inbox.items | Where-Object { $_.relativePath -eq '00-Inbox.md' }).Count -eq 0) 'The folder index note must never appear as an inbox item.'
    Assert-True (@($inbox.items | Where-Object { $_.relativePath -eq 'clip\nested-note.md' }).Count -eq 1) 'Inbox items must carry a path relative to the inbox folder.'
    $textItem = @($inbox.items | Where-Object { $_.relativePath -eq '随手记.md' })[0]
    Assert-True ($textItem.isPlainText -eq $true) 'A Markdown drop must be reported as directly readable.'
    Assert-True ($textItem.extension -eq '.md' -and [long]$textItem.sizeBytes -gt 0 -and [bool]$textItem.modifiedUtc) 'Inbox items must carry extension, size, and modification time.'
    $binaryItem = @($inbox.items | Where-Object { $_.relativePath -eq 'photo.png' })[0]
    Assert-True ($binaryItem.isPlainText -eq $false) 'A binary drop must not be reported as directly readable.'
    Assert-True (@($inbox.emptyDirectories) -contains 'keep-empty') 'An empty dropped folder must still be visible to the caller.'

    # --- InboxClear: filed items move to the archive instead of being deleted ---
    $clear = Invoke-JsonCommand -Tool $tool -Parameters @{
        Command = 'InboxClear'
        ConfigPath = $configPath
        ItemIds = @('随手记.md', 'clip\nested-note.md')
    }
    Assert-True ($clear.movedCount -eq 2) 'InboxClear must move exactly the requested items.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $inboxFolder '随手记.md'))) 'A cleared item must leave its inbox position.'
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$clear.archiveRoot) '随手记.md') -PathType Leaf) 'A cleared item must land in the timestamped archive.'
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$clear.archiveRoot) 'clip\nested-note.md') -PathType Leaf) 'The archive must preserve the inbox-relative layout.'
    Assert-True (Test-PathWithin ([string]$clear.archiveRoot) $data) 'The inbox archive must live under controllerDataRoot.'
    Assert-True (@($clear.prunedDirectories) -contains 'clip') 'A folder emptied by clearing must not be left behind.'
    Assert-True (Test-Path -LiteralPath $inboxKeepEmpty -PathType Container) 'A folder that was already empty was not emptied by this run and must survive.'
    $inboxAfterClear = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Inbox'; ConfigPath = $configPath }
    Assert-True ($inboxAfterClear.count -eq 2) 'Only uncleared items may remain in the inbox.'

    # --- InboxClear: unknown items are an error, never a silent success ---
    $unknownThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('没有这个东西.md') }
    } catch {
        $unknownThrown = $_.Exception.Message.Contains('Unknown inbox item')
    }
    Assert-True $unknownThrown 'InboxClear must fail loudly on an item that is not in the inbox.'

    $partialThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('snippet.txt', '没有这个东西.md') }
    } catch {
        $partialThrown = $_.Exception.Message.Contains('Unknown inbox item')
    }
    Assert-True $partialThrown 'A bad id anywhere in the list must abort the whole clear.'
    Assert-True (Test-Path -LiteralPath (Join-Path $inboxFolder 'snippet.txt') -PathType Leaf) 'A failed clear must not move any item.'

    # --- InboxClear: escapes and the index note are refused ---
    $escapeThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('..\04-Work\Example.md') }
    } catch {
        $escapeThrown = $_.Exception.Message.Contains('outside the inbox folder')
    }
    Assert-True $escapeThrown 'InboxClear must refuse paths that escape the inbox folder.'
    $indexThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('00-Inbox.md') }
    } catch {
        $indexThrown = $_.Exception.Message.Contains('index note')
    }
    Assert-True $indexThrown 'InboxClear must refuse to move the inbox index note.'
    Assert-True (Test-Path -LiteralPath (Join-Path $inboxFolder '00-Inbox.md') -PathType Leaf) 'The inbox index note must survive every clear.'

    # --- InboxClear: a dropped folder clears as one unit, overlaps are refused ---
    $inboxBundle = Join-Path $inboxFolder 'bundle'
    New-Item -ItemType Directory -Path $inboxBundle -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $inboxBundle 'a.md'), 'a', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $inboxBundle 'b.md'), 'b', [Text.UTF8Encoding]::new($false))
    $overlapThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('bundle', 'bundle\a.md') }
    } catch {
        $overlapThrown = $_.Exception.Message.Contains('overlap')
    }
    Assert-True $overlapThrown 'Clearing a folder and its contents in one call must be refused, not half-applied.'
    Assert-True (Test-Path -LiteralPath (Join-Path $inboxBundle 'a.md') -PathType Leaf) 'A refused overlap must leave the inbox untouched.'
    $bundleClear = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'InboxClear'; ConfigPath = $configPath; ItemIds = @('bundle') }
    Assert-True (@($bundleClear.moved)[0].kind -eq 'directory') 'A dropped folder must clear as a single directory item.'
    Assert-True (-not (Test-Path -LiteralPath $inboxBundle)) 'A cleared folder must leave the inbox.'
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$bundleClear.archiveRoot) 'bundle\b.md') -PathType Leaf) 'A cleared folder must reach the archive with its contents.'

    # --- Inbox: an unconfigured inbox is an explicit error ---
    $noInboxConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $noInboxConfig.destinations.PSObject.Properties.Remove('inbox')
    $noInboxConfigPath = Join-Path $testRoot 'config-noinbox.json'
    [IO.File]::WriteAllText($noInboxConfigPath, ($noInboxConfig | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $noInboxThrown = $false
    try {
        $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Inbox'; ConfigPath = $noInboxConfigPath }
    } catch {
        $noInboxThrown = $_.Exception.Message.Contains('destinations.inbox')
    }
    Assert-True $noInboxThrown 'Inbox must say plainly that destinations.inbox is unconfigured.'

    [ordered]@{
        status = 'PASS'
        tests = @(
            'doctor'
            'doctor unknown-key warnings'
            'doctor invalid values and unsafe layouts'
            'newconfig onboarding'
            'schema validation (pwsh only)'
            'metadata-only catalog'
            'metadata directory pruning'
            'catalog human-file refusal'
            'catalog optional metadata section'
            'lossless queue'
            'semantic directory pruning'
            'consent quarantine and prefix approve'
            'fair batching'
            'oversized exclusion'
            'prefix acknowledgement'
            'marker-bounded safe write'
            'conflict detection'
            'incomplete-marker refusal'
            'backup'
            'supersede'
            'supersededUtc stamping and requeue refusal'
            'missing sweep'
            'junction pruning'
            'fail and requeue'
            'compact aging by terminal time'
            'compact archive'
            'backup pruning'
            'retroactive excludedPaths'
            'discover consent gate'
            'discover empty roots'
            'report'
            'oldest-backlog fairness'
            'inbox listing excludes the folder index note'
            'inbox plain-text detection'
            'inbox clear moves to archive'
            'inbox clear prunes emptied folders only'
            'inbox clear rejects unknown items'
            'inbox clear is all-or-nothing'
            'inbox clear containment and index-note refusal'
            'inbox clear folder as one unit and overlap refusal'
            'inbox unconfigured error'
        )
    } | ConvertTo-Json -Depth 4
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = Normalize-Path $testRoot
        if (-not (Test-PathWithin $resolvedTestRoot $resolvedTempRoot)) {
            throw "Refusing to clean unexpected test path: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
