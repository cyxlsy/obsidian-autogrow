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
    [IO.File]::WriteAllText((Join-Path $sourceB 'beta-report.md'), 'beta', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceB 'beta-code.py'), 'print(1)', [Text.UTF8Encoding]::new($false))
    $metadataProject = Join-Path $sourceMetadata 'wrapper\account\cloud\客户项目'
    New-Item -ItemType Directory -Path $metadataProject -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $metadataProject 'test.docx'), 'secret-content-must-not-appear', [Text.UTF8Encoding]::new($false))

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
        destinations = [ordered]@{ home = '00-Home'; workProjects = '04-Work' }
        scanPolicy = [ordered]@{
            stableMinutes = 0
            initialLookbackDays = 10
            maxFilesPerBatch = 2
            maxTopicsPerRun = 2
            maxSemanticFileBytes = 1048576
            allowedExtensions = @('.md', '.txt', '.py')
            highValueExtensions = @('.md')
            highValueNameFragments = @('final', 'report')
        }
        privacy = [ordered]@{
            ignoredDirectories = @('.git', 'node_modules')
            ignoredFileNames = @('.env')
            ignoredNameFragments = @('token', 'secret')
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

    $doctor = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Doctor'; ConfigPath = $configPath }
    Assert-True ($doctor.status -eq 'OK') 'Doctor should pass for isolated paths.'

    $null = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Init'; ConfigPath = $configPath }
    $catalog = Invoke-JsonCommand -Tool $catalogTool -Parameters @{ ConfigPath = $configPath }
    Assert-True ($catalog.contentRead -eq $false) 'Metadata catalog must report contentRead=false.'
    $catalogText = Get-Content -LiteralPath (Join-Path $vault '04-Work\Catalog.md') -Raw -Encoding UTF8
    Assert-True ($catalogText.Contains('test.docx')) 'Metadata catalog must include the filename.'
    Assert-True ($catalogText.Contains('客户项目')) 'Metadata grouping must strip wrapper segments.'
    Assert-True (-not $catalogText.Contains('secret-content-must-not-appear')) 'Metadata catalog must not copy file content.'
    $scan = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Scan'; ConfigPath = $configPath }
    Assert-True ($scan.enqueued -eq 4) 'First scan should enqueue all four files.'
    Assert-True ($scan.pending -eq 4) 'No queued file may be lost behind batch caps.'

    $next = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Next'; ConfigPath = $configPath }
    Assert-True ($next.count -eq 2) 'Next must respect maxFilesPerBatch.'
    $sourceCount = @($next.items.sourceId | Sort-Object -Unique).Count
    Assert-True ($sourceCount -eq 2) 'Fair batch should include both sources.'

    $ids = @($next.items.id)
    $null = & $tool -Command Ack -ConfigPath $configPath -ItemIds $ids | Out-String
    $status = Invoke-JsonCommand -Tool $tool -Parameters @{ Command = 'Status'; ConfigPath = $configPath }
    Assert-True ($status.counts.processed -eq 2) 'Ack should process only selected items.'
    Assert-True ($status.counts.pending -eq 2) 'Unselected items must remain pending.'

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

    [ordered]@{
        status = 'PASS'
        tests = @(
            'doctor'
            'lossless queue'
            'fair batching'
            'acknowledgement'
            'marker-bounded safe write'
            'backup'
            'metadata-only catalog'
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
