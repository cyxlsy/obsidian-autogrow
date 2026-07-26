# Shared helpers for grow-obsidian scripts.
# Dot-source from a sibling script:
#   . (Join-Path $PSScriptRoot 'common.ps1')

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

function Test-HasProperty {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return $false
    }
    return @($Object.PSObject.Properties.Name) -contains $Name
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

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-TextAtomic {
    param(
        [string]$Path,
        [string]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.grow-obsidian-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
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

function Write-JsonAtomic {
    param(
        [string]$Path,
        [object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 12
    Write-TextAtomic -Path $Path -Content ($json + [Environment]::NewLine)
}

function Set-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )
    Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-CandidateFiles {
    # Iterative walk that prunes ignored and dotted directories instead of
    # enumerating the whole tree and filtering afterwards. Junctions and
    # symbolic links are pruned to avoid cycles, but other reparse points
    # (OneDrive/Google Drive cloud placeholders carry the reparse attribute
    # too) are descended so cloud-synced sources are not silently skipped.
    # A depth cap backstops any cycle the link check cannot see. Directories
    # that cannot be listed are counted through the optional [ref].
    param(
        [string]$Root,
        [string[]]$IgnoredDirectoryNames = @(),
        [ref]$InaccessibleCount
    )
    $maxDepth = 100
    $results = [System.Collections.Generic.List[IO.FileInfo]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@([IO.DirectoryInfo]::new($Root), 0))
    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $directory = [IO.DirectoryInfo]$frame[0]
        $depth = [int]$frame[1]
        $entries = $null
        try {
            $entries = $directory.GetFileSystemInfos()
        } catch {
            if ($InaccessibleCount) {
                $InaccessibleCount.Value++
            }
            continue
        }
        foreach ($entry in $entries) {
            if ($entry -is [IO.DirectoryInfo]) {
                $name = $entry.Name.ToLowerInvariant()
                if ($name.StartsWith('.')) {
                    continue
                }
                if ($IgnoredDirectoryNames -contains $name) {
                    continue
                }
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $linkType = $null
                    try {
                        $linkType = $entry.LinkType
                    } catch {
                        $linkType = $null
                    }
                    if ($linkType -eq 'Junction' -or $linkType -eq 'SymbolicLink') {
                        continue
                    }
                }
                if ($depth -ge $maxDepth) {
                    if ($InaccessibleCount) {
                        $InaccessibleCount.Value++
                    }
                    continue
                }
                $stack.Push(@($entry, $depth + 1))
            } elseif ($entry -is [IO.FileInfo]) {
                $results.Add($entry)
            }
        }
    }
    return ,$results
}
