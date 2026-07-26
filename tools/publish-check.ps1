# publish-check.ps1
# Pre-publish privacy checker for the Obsidian AutoGrow repository.
# Fails (exit 1) when tracked paths, tracked file contents, or git history
# contain private data that must never be published.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Get-Truncated {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text.Trim()
    if ($t.Length -gt 60) { return ($t.Substring(0, 60) + '...') }
    return $t
}

$errors = New-Object System.Collections.ArrayList
$scannedFiles = 0
$historyPatterns = 0

# ---------------------------------------------------------------------------
# Step 0: enumerate tracked files
# ---------------------------------------------------------------------------
$tracked = @(git -C $RepoRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    $result = New-Object PSObject
    $result | Add-Member NoteProperty status 'FAIL'
    $result | Add-Member NoteProperty errors @('git ls-files failed; is this a git repository?')
    $result | Add-Member NoteProperty scannedFiles 0
    $result | Add-Member NoteProperty historyPatterns 0
    $result | ConvertTo-Json -Depth 5
    exit 1
}

# ---------------------------------------------------------------------------
# Step 1: forbidden tracked paths
# ---------------------------------------------------------------------------
foreach ($path in $tracked) {
    if ($null -eq $path -or $path -eq '') { continue }
    $leaf = ($path -split '/')[-1]
    $reason = ''
    if ($leaf -like 'config.local.json') { $reason = 'config.local.json must never be tracked' }
    elseif ($leaf -like '*.local.json') { $reason = '*.local.json files must never be tracked' }
    elseif ($leaf -like '*.log') { $reason = '*.log files must never be tracked' }
    elseif ($path -match '^\.local/') { $reason = '.local/ directory must never be tracked' }
    elseif ($path -match '^backups/') { $reason = 'backups/ directory must never be tracked' }
    elseif ($path -match '^exports/') { $reason = 'exports/ directory must never be tracked' }
    elseif ($path -match '^discovery-output/') { $reason = 'discovery-output/ directory must never be tracked' }
    if ($reason -ne '') {
        [void]$errors.Add(('TRACKED-PATH ' + $path + ': ' + $reason))
    }
}

# ---------------------------------------------------------------------------
# Step 2: load optional private patterns
# ---------------------------------------------------------------------------
$privatePatterns = @()
$patternFile = Join-Path $RepoRoot '.publish-private-patterns.local.txt'
if (Test-Path -LiteralPath $patternFile) {
    $rawLines = @([System.IO.File]::ReadAllLines($patternFile))
    foreach ($rawLine in $rawLines) {
        if ($null -eq $rawLine) { continue }
        $line = $rawLine.Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) { continue }
        $privatePatterns += $line
    }
}
$historyPatterns = $privatePatterns.Count

# ---------------------------------------------------------------------------
# Step 3: content scan of tracked text files
# ---------------------------------------------------------------------------
$textExtensions = @('.md', '.ps1', '.json', '.yml', '.yaml', '.txt')

# Windows drive path whose path portion contains a non-ASCII character
# (personal folder names are the main leak risk).
$nonAsciiPathRegex = '[A-Za-z]:\\[A-Za-z0-9_\\./~ +-]{0,80}[^\x00-\x7F]'

# Generic email address; allowlisted domains are filtered afterwards.
$emailRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
$allowedEmailRegex = '(users\.noreply\.github\.com|(^|[.@])example\.com)$'

foreach ($path in $tracked) {
    if ($null -eq $path -or $path -eq '') { continue }
    $leaf = ($path -split '/')[-1]
    $ext = [System.IO.Path]::GetExtension($leaf)

    $shouldScan = $false
    if ($ext -eq '') {
        $shouldScan = $true   # extensionless, e.g. LICENSE
    }
    elseif ($textExtensions -contains $ext.ToLower()) {
        $shouldScan = $true
    }
    elseif ($leaf.StartsWith('.') -and $leaf.IndexOf('.', 1) -lt 0) {
        $shouldScan = $true   # dotfiles like .gitignore, .editorconfig
    }
    if (-not $shouldScan) { continue }

    $fullPath = Join-Path $RepoRoot ($path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $fullPath)) { continue }

    $lines = @([System.IO.File]::ReadAllLines($fullPath))
    $scannedFiles = $scannedFiles + 1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -eq $line -or $line -eq '') { continue }
        $lineNo = $i + 1

        # (1) non-ASCII Windows drive paths
        $pathMatches = [regex]::Matches($line, $nonAsciiPathRegex)
        foreach ($m in $pathMatches) {
            [void]$errors.Add(('CONTENT non-ascii-path ' + $path + ':' + $lineNo + ': ' + (Get-Truncated $m.Value)))
        }

        # (2) email addresses outside the allowlist
        $emailMatches = [regex]::Matches($line, $emailRegex)
        foreach ($m in $emailMatches) {
            if ($m.Value -inotmatch $allowedEmailRegex) {
                [void]$errors.Add(('CONTENT email ' + $path + ':' + $lineNo + ': ' + (Get-Truncated $m.Value)))
            }
        }

        # (3) user-registered private substrings
        foreach ($pattern in $privatePatterns) {
            if ($line.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$errors.Add(('CONTENT private-pattern "' + (Get-Truncated $pattern) + '" ' + $path + ':' + $lineNo + ': ' + (Get-Truncated $line)))
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 4: git history scan for private patterns
# ---------------------------------------------------------------------------
if ($privatePatterns.Count -gt 0) {
    $allCommits = @(git -C $RepoRoot rev-list --all)
    if ($LASTEXITCODE -ne 0) {
        $allCommits = @()
        [void]$errors.Add('HISTORY: git rev-list --all failed; history could not be scanned')
    }

    if ($allCommits.Count -gt 0) {
        foreach ($pattern in $privatePatterns) {
            $hits = New-Object System.Collections.ArrayList
            # Chunk the commit list to keep the command line short enough.
            $chunkSize = 100
            for ($start = 0; $start -lt $allCommits.Count; $start += $chunkSize) {
                $end = [Math]::Min($start + $chunkSize, $allCommits.Count) - 1
                $chunk = @($allCommits[$start..$end])
                $grepArgs = @('-C', $RepoRoot, 'grep', '-l', '--fixed-strings', '--ignore-case', '-e', $pattern) + $chunk
                $grepOut = @(& git $grepArgs)
                # git grep exit codes: 0 = matches found, 1 = no match (fine), >1 = error
                if ($LASTEXITCODE -eq 0) {
                    foreach ($hit in $grepOut) {
                        if ($null -ne $hit -and $hit -ne '') { [void]$hits.Add($hit) }
                    }
                }
                elseif ($LASTEXITCODE -gt 1) {
                    [void]$errors.Add(('HISTORY: git grep failed (exit ' + $LASTEXITCODE + ') for pattern "' + (Get-Truncated $pattern) + '"'))
                }
            }
            if ($hits.Count -gt 0) {
                $sample = Get-Truncated ([string]$hits[0])
                [void]$errors.Add(('HISTORY private-pattern "' + (Get-Truncated $pattern) + '" appears in git history (' + $hits.Count + ' commit:file hit(s), e.g. ' + $sample + '). Removing it requires rewriting history (e.g. git filter-repo) before publishing.'))
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: report
# ---------------------------------------------------------------------------
$status = 'OK'
if ($errors.Count -gt 0) { $status = 'FAIL' }

$result = New-Object PSObject
$result | Add-Member NoteProperty status $status
$result | Add-Member NoteProperty errors @($errors.ToArray())
$result | Add-Member NoteProperty scannedFiles $scannedFiles
$result | Add-Member NoteProperty historyPatterns $historyPatterns
$result | ConvertTo-Json -Depth 5

if ($status -eq 'OK') { exit 0 }
exit 1
