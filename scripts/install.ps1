#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
Install, check, or update the prototype-first OpenSpec schema in a project.

.DESCRIPTION
The schema is installed into ./openspec/schemas/prototype-first and selected in
./openspec/config.yaml. Run from an OpenSpec project root, or pass -Dir.

Remote:
  irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1 | iex

Pass options remotely with a script block:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1))) -NoSelect

Local (from a clone of this repository):
  ./scripts/install.ps1

Design notes:
- Installs are pinned to a release tag ($DefaultRef) rather than the tip of
  main, so recurring installs are reproducible.
- Every install writes openspec/schemas/prototype-first/.install.json with the
  version, ref, source, timestamp, and a SHA-256 per file. -Check and -Upgrade
  use it to know what is installed and whether a file was edited.
- The script also runs through `irm | iex`. In that mode $PSScriptRoot is empty
  and calling exit would close the user's shell, so Complete() sets
  $LASTEXITCODE instead of exiting.

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
./scripts/install.ps1 -Dir C:\src\my-project -Check

.EXAMPLE
./scripts/install.ps1 -Dir C:\src\my-project -Upgrade
#>
[CmdletBinding()]
param(
    [string]$Dir,
    [string]$BaseUrl,
    [string]$Ref,
    [switch]$Select,
    [switch]$NoSelect,
    [switch]$Force,
    [switch]$Check,
    [switch]$Upgrade,
    [switch]$Version,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # Older runtimes may not expose Tls12; Invoke-WebRequest still uses their default.
}

$SchemaName = 'prototype-first'
# Release tag installed by default. release-please rewrites the version on this
# exact line when it prepares a release, so keep the annotation and the
# `$DefaultRef = 'vX.Y.Z'` shape intact.
$DefaultRef = 'v1.1.0' # x-release-please-version
$DefaultRepoUrl = 'https://raw.githubusercontent.com/tiagosantini/openspec-schemas'
# Files that make up the installed schema. The stamp is deliberately absent: it
# is generated after the copy and must never be hashed or downloaded.
$Files = @(
    'README.md'
    'schema.yaml'
    'templates/design.md'
    'templates/proposal.md'
    'templates/prototype.html'
    'templates/spec.md'
    'templates/tasks.md'
)

function Fail {
    # In file mode the exit code is the contract. Through `irm | iex` exiting
    # would close the caller's shell, so throw instead.
    param([string]$Message)
    if ($PSScriptRoot) {
        [Console]::Error.WriteLine("error: $Message")
        exit 1
    }
    throw "error: $Message"
}

function Complete {
    # Used by the read-only modes (-Check, -Version), which return a status
    # code without terminating an interactive session.
    param([int]$Code)
    if ($PSScriptRoot) {
        exit $Code
    }
    $global:LASTEXITCODE = $Code
}

function Show-Usage {
    @"
Install, check, or update the $SchemaName OpenSpec schema.

Usage:
  scripts/install.ps1 [options]

Options:
  -Dir <path>    Project root to install into (default: current directory)
  -Ref <ref>     Release tag or branch to install (default: $DefaultRef)
  -Check         Report whether the installed schema is up to date
  -Upgrade       Update an existing installation, refusing local changes
  -Force         Overwrite local changes and reinstall even when up to date
  -Version       Print the installed schema version
  -Select        Select the schema in openspec/config.yaml (default)
  -NoSelect      Leave openspec/config.yaml unchanged
  -BaseUrl <url> Schema base URL, overriding -Ref and the repository URL
  -Help          Show this help

Exit codes for -Check:
  0  installed version is current
  1  update available, or the schema is not installed
  2  the latest version could not be determined

Environment:
  SCHEMA_REF         Release tag or branch to install
  SCHEMA_REPO_URL    Repository raw URL (default: $DefaultRepoUrl)
  SCHEMA_BASE_URL    Full schema base URL, overriding SCHEMA_REF and SCHEMA_REPO_URL
  SCHEMA_VERSION     Record this version instead of reading version.txt
  SCHEMA_TARGET_DIR  Project root (same as -Dir)

The script uses the local schemas/$SchemaName directory when run from a
checkout of this repository. Otherwise it downloads the schema from the ref.
"@ | Write-Host
}

function Invoke-Download {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -ErrorAction Stop
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds 2
            }
        }
    }

    Fail "could not download ${Uri}: $($lastError.Exception.Message)"
}

function Try-Download {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Read-VersionFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return ([IO.File]::ReadAllText($Path)).Trim()
}

function Get-NormalizedVersion {
    param([string]$Value)
    if (-not $Value) {
        return ''
    }
    return ($Value -replace '^v', '') -replace '[-+].*$', ''
}

function Compare-Version {
    # Returns 1 when Left > Right, -1 when Left < Right, 0 when equal. The
    # comparison is component-wise over X.Y.Z so it does not depend on
    # [version], which rejects pre-release suffixes.
    param(
        [string]$Left,
        [string]$Right
    )

    $leftParts = (Get-NormalizedVersion $Left).Split('.')
    $rightParts = (Get-NormalizedVersion $Right).Split('.')
    $length = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $length; $i++) {
        $leftValue = 0
        $rightValue = 0
        if ($i -lt $leftParts.Count) {
            [void][int]::TryParse($leftParts[$i], [ref]$leftValue)
        }
        if ($i -lt $rightParts.Count) {
            [void][int]::TryParse($rightParts[$i], [ref]$rightValue)
        }
        if ($leftValue -gt $rightValue) {
            return 1
        }
        if ($leftValue -lt $rightValue) {
            return -1
        }
    }
    return 0
}

function Get-StampText {
    # The stamp is read once and the field helpers below parse it in memory.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [IO.File]::ReadAllText($Path)
}

function Get-StampField {
    # Matches a top-level `"name": "value"` pair regardless of indentation, so
    # a stamp written by install.sh and one written by ConvertTo-Json both work.
    param(
        [string]$StampText,
        [string]$Name
    )
    if (-not $StampText) {
        return ''
    }
    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"([^"]*)"'
    $match = [regex]::Match($StampText, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ''
}

function Get-StampHash {
    # Hashes are stored as 64 lowercase hex characters; anything else means the
    # file was not recorded and drift detection skips it.
    param(
        [string]$StampText,
        [string]$Name
    )
    if (-not $StampText) {
        return ''
    }
    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"([0-9a-fA-F]{64})"'
    $match = [regex]::Match($StampText, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.ToLowerInvariant()
    }
    return ''
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-StampFile {
    # Records what was installed so -Check, -Version, and -Upgrade have a
    # baseline. ConvertTo-Json output differs from install.sh's hand-written
    # JSON only in indentation, which both readers tolerate.
    param(
        [string]$Path,
        [string]$Dest,
        [string]$TargetVersion,
        [string]$TargetRef,
        [string]$Source
    )

    $hashes = [ordered]@{}
    foreach ($file in $Files) {
        $hashes[$file] = Get-Sha256 (Join-Path $Dest $file)
    }
    $stamp = [ordered]@{
        schema      = $SchemaName
        version     = $TargetVersion
        ref         = $TargetRef
        source      = $Source
        installedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        files       = $hashes
    }
    $json = $stamp | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($Path, $json + "`n")
}

function Invoke-Installer {
    if ($Help) {
        Show-Usage
        return
    }

    if (-not $Dir) {
        $Dir = $env:SCHEMA_TARGET_DIR
    }
    if (-not $Dir) {
        $Dir = (Get-Location).Path
    }

    $refSet = $false
    if (-not $Ref) {
        $Ref = $env:SCHEMA_REF
    }
    if ($Ref) {
        $refSet = $true
    }
    else {
        $Ref = $DefaultRef
    }

    $repoSet = $false
    if (-not $BaseUrl) {
        $BaseUrl = $env:SCHEMA_BASE_URL
    }
    $repoUrl = $env:SCHEMA_REPO_URL
    if ($repoUrl) {
        $repoSet = $true
    }
    else {
        $repoUrl = $DefaultRepoUrl
    }
    if ($BaseUrl) {
        # Mirrors and the CI HTTP server provide a full schema URL. Recover the
        # repository root from it so version.txt can still be resolved.
        $suffix = "/schemas/$SchemaName"
        if (-not $repoSet -and $BaseUrl.EndsWith($suffix)) {
            $repoUrl = $BaseUrl.Substring(0, $BaseUrl.Length - $suffix.Length)
        }
    }
    else {
        $BaseUrl = "$repoUrl/$Ref/schemas/$SchemaName"
    }

    # Refs are interpolated into URLs: accept only plain tag or branch names.
    # `..`, a leading dot, and leading/trailing slashes are rejected because
    # they could escape the intended path.
    if ($Ref -notmatch '^[A-Za-z0-9._/-]+$' -or $Ref.StartsWith('-') -or $Ref.StartsWith('.') -or
        $Ref.Contains('..') -or $Ref.StartsWith('/') -or $Ref.EndsWith('/')) {
        Fail "invalid ref: $Ref"
    }

    if ($Check -and $Upgrade) {
        Fail 'use either -Check or -Upgrade, not both'
    }
    if ($Version -and ($Check -or $Upgrade)) {
        Fail 'use -Version on its own'
    }
    if ($NoSelect -and $Select) {
        Fail 'use either -Select or -NoSelect, not both'
    }
    $selectSchema = -not $NoSelect
    if ($Select) {
        $selectSchema = $true
    }

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Fail "target directory does not exist: $Dir"
    }
    $targetDir = (Resolve-Path -LiteralPath $Dir).Path
    $openspecDir = Join-Path $targetDir 'openspec'
    $configPath = Join-Path $openspecDir 'config.yaml'
    $schemasDir = Join-Path $openspecDir 'schemas'
    $dest = Join-Path $schemasDir $SchemaName
    $stampPath = Join-Path $dest '.install.json'
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("$SchemaName." + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $cleanupWorkDir = $true

    try {
        $localSource = $null
        $repoRoot = $null
        if ($PSScriptRoot) {
            $repoRoot = Split-Path -Parent $PSScriptRoot
            $candidate = Join-Path (Join-Path $repoRoot 'schemas') $SchemaName
            if (Test-Path -LiteralPath (Join-Path $candidate 'schema.yaml') -PathType Leaf) {
                $localSource = $candidate
            }
        }

        # The version comes from the local checkout when available, otherwise
        # from version.txt at the selected ref (or the repository root, which
        # only moves when a release PR is merged).
        $targetVersion = $env:SCHEMA_VERSION
        if (-not $targetVersion) {
            if ($localSource) {
                $targetVersion = Read-VersionFile (Join-Path $repoRoot 'version.txt')
            }
            else {
                $versionUrl = if ($refSet) { "$repoUrl/$Ref/version.txt" } else { "$repoUrl/version.txt" }
                $versionFile = Join-Path $workDir 'version.txt'
                if (Try-Download -Uri $versionUrl -OutFile $versionFile) {
                    $targetVersion = Read-VersionFile $versionFile
                }
            }
        }

        $stampText = Get-StampText $stampPath
        $installedVersion = Get-StampField -StampText $stampText -Name 'version'

        # Drift = files whose hash differs from the install-time hash. It needs
        # a stamp as the baseline; legacy installs are handled by keeping a
        # persistent backup before replacement instead of blocking.
        $drift = @()
        if ($stampText) {
            foreach ($file in $Files) {
                $expected = Get-StampHash -StampText $stampText -Name $file
                if (-not $expected) {
                    continue
                }
                $installedFile = Join-Path $dest $file
                if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf)) {
                    $drift += "deleted: $file"
                }
                elseif ((Get-Sha256 $installedFile) -ne $expected) {
                    $drift += "modified: $file"
                }
            }
        }

        # -Version is read-only and always succeeds: it reports what is
        # installed, including "unknown" for pre-stamp installations. Output
        # goes to the pipeline so callers can capture and parse it.
        if ($Version) {
            if ($stampText) {
                Write-Output "Installed: $(if ($installedVersion) { $installedVersion } else { 'unknown' }) (ref $(Get-StampField -StampText $stampText -Name 'ref'))"
                Write-Output "Path: $dest"
            }
            elseif (Test-Path -LiteralPath $dest) {
                Write-Output 'Installed: unknown (no version stamp; reinstall to start tracking)'
                Write-Output "Path: $dest"
            }
            else {
                Write-Output "Not installed in $targetDir"
            }
            Complete 0
            return
        }

        # -Check never touches the project. Exit codes are the interface:
        # 0 current, 1 outdated/not installed, 2 latest version unknown.
        if ($Check) {
            if (-not (Test-Path -LiteralPath $dest)) {
                Write-Host "Not installed in $targetDir"
                Write-Host 'Install it with: ./scripts/install.ps1'
                Complete 1
                return
            }
            if (-not $installedVersion) {
                Write-Host 'Installed: unknown (no version stamp; reinstall to start tracking)'
                Complete 1
                return
            }
            if (-not $targetVersion) {
                Write-Host "Installed: $installedVersion"
                [Console]::Error.WriteLine('error: could not determine the latest version')
                Complete 2
                return
            }
            if ((Get-NormalizedVersion $installedVersion) -eq (Get-NormalizedVersion $targetVersion)) {
                Write-Host "Up to date: $installedVersion"
                Complete 0
                return
            }
            if ((Compare-Version $installedVersion $targetVersion) -gt 0) {
                Write-Host "Installed $installedVersion is newer than $targetVersion"
                Complete 0
                return
            }
            Write-Host "Update available: $installedVersion -> $targetVersion"
            Write-Host 'Run with -Upgrade to apply it'
            Complete 1
            return
        }

        if ($Upgrade -and -not (Test-Path -LiteralPath $dest)) {
            Fail "no installation found at $dest; run without -Upgrade to install"
        }

        # Refuse to destroy work: any edited file aborts the upgrade before
        # anything is downloaded or replaced.
        if ($drift.Count -gt 0 -and -not $Force) {
            [Console]::Error.WriteLine('error: local changes detected in the installed schema; nothing was replaced.')
            [Console]::Error.WriteLine('These files differ from the installed version:')
            foreach ($entry in $drift) {
                [Console]::Error.WriteLine("  $entry")
            }
            [Console]::Error.WriteLine('Review them, then re-run with -Force to overwrite.')
            Complete 1
            return
        }

        # Idempotent re-runs: same version and no drift is a no-op. -Force
        # bypasses this to repair a damaged installation.
        if (-not $Force -and $installedVersion -and $targetVersion -and
            (Get-NormalizedVersion $installedVersion) -eq (Get-NormalizedVersion $targetVersion) -and
            $drift.Count -eq 0) {
            Write-Host "Already up to date: $installedVersion at $dest"
            Complete 0
            return
        }

        if (-not (Test-Path -LiteralPath $openspecDir -PathType Container)) {
            Fail "no openspec/ directory in $targetDir. Run 'openspec init' first, or pass -Dir <project-root>"
        }
        if ($selectSchema -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            Fail "openspec/config.yaml not found in $targetDir. Run 'openspec init' first, or pass -NoSelect"
        }

        $stage = Join-Path $workDir $SchemaName
        $backup = $null

        # Build the complete schema in the staging directory first. The project
        # stays untouched until every file has arrived and the schema name
        # checks out, so a failed download leaves the current install intact.
        if ($localSource) {
            Write-Host "Installing from $localSource"
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Get-ChildItem -LiteralPath $localSource -Force |
                Copy-Item -Destination $stage -Recurse -Force
            $sourceDescription = $localSource
            $targetRef = 'local'
        }
        else {
            Write-Host "Downloading $Ref from $BaseUrl"
            foreach ($file in $Files) {
                $destFile = Join-Path $stage $file
                $parent = Split-Path -Parent $destFile
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Invoke-Download -Uri "$BaseUrl/$file" -OutFile $destFile
            }
            $sourceDescription = $BaseUrl
            $targetRef = $Ref
        }

        foreach ($file in $Files) {
            $path = Join-Path $stage $file
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if (-not $item -or $item.Length -le 0) {
                Fail "downloaded schema is missing $file"
            }
        }
        $schemaText = [IO.File]::ReadAllText((Join-Path $stage 'schema.yaml'))
        if ($schemaText -notmatch "(?m)^name:\s+$([regex]::Escape($SchemaName))\s*$") {
            Fail "schema.yaml does not declare 'name: $SchemaName'"
        }

        New-Item -ItemType Directory -Path $schemasDir -Force | Out-Null
        if (Test-Path -LiteralPath $dest) {
            # Legacy installs (no stamp) and forced overwrites keep a durable
            # copy outside schemas/ so schema discovery never treats a backup
            # as a schema. Clean reinstallations use the temporary rollback
            # below instead.
            if (-not $stampText -or $drift.Count -gt 0) {
                $backupStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
                $persistentBackup = Join-Path (Join-Path $openspecDir '.schema-backups') "$SchemaName-$backupStamp"
                New-Item -ItemType Directory -Path (Split-Path -Parent $persistentBackup) -Force | Out-Null
                Copy-Item -LiteralPath $dest -Destination $persistentBackup -Recurse -Force
                Write-Host "Saved the previous installation to $persistentBackup"
            }
            $backup = Join-Path $workDir 'previous'
            Write-Host "Replacing existing installation at $dest"
            Move-Item -LiteralPath $dest -Destination $backup
        }

        try {
            Move-Item -LiteralPath $stage -Destination $dest

            # Validate in the project itself because resolution depends on the
            # project layout. On failure the new copy is removed and the
            # temporary backup restored, keeping the previous version usable.
            $openspec = Get-Command openspec -ErrorAction SilentlyContinue
            if ($openspec) {
                $global:LASTEXITCODE = 0
                $validationOutput = @()
                $validationExitCode = 0
                Push-Location $targetDir
                try {
                    $validationOutput = & openspec schema validate $SchemaName 2>&1
                    $validationExitCode = $LASTEXITCODE
                }
                finally {
                    Pop-Location
                }
                if ($validationExitCode -ne 0) {
                    $validationOutput | Write-Host
                    if ($backup) {
                        throw 'schema validation failed; previous installation restored'
                    }
                    throw 'schema validation failed'
                }
                Write-Host "Validated schema '$SchemaName'"
            }
            else {
                Write-Warning 'openspec CLI not found; skipped validation'
            }

            if (-not $targetVersion) {
                $targetVersion = 'unknown'
            }
            # A stamp failure must not roll back an otherwise valid install.
            try {
                Write-StampFile -Path $stampPath -Dest $dest -TargetVersion $targetVersion -TargetRef $targetRef -Source $sourceDescription
            }
            catch {
                Write-Warning "could not write ${stampPath}: $($_.Exception.Message)"
            }
        }
        catch {
            $restoreError = $null
            if (Test-Path -LiteralPath $dest) {
                Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($backup -and (Test-Path -LiteralPath $backup)) {
                try {
                    Move-Item -LiteralPath $backup -Destination $dest -ErrorAction Stop
                }
                catch {
                    $restoreError = $_
                    $cleanupWorkDir = $false
                }
            }
            if ($restoreError) {
                throw "error: could not restore the previous installation. It is kept at $backup. $($restoreError.Exception.Message)"
            }
            throw
        }

        if ($selectSchema) {
            # Selection is a single `schema:` key. Replacing just that line keeps
            # comments and the rest of config.yaml intact and makes re-runs
            # idempotent. Line endings are preserved for Windows projects.
            $configText = [IO.File]::ReadAllText($configPath)
            $newLine = if ($configText.Contains("`r`n")) { "`r`n" } else { "`n" }
            if ($configText -match '(?m)^schema:') {
                $configText = [regex]::Replace($configText, '(?m)^schema:[^\r\n]*', "schema: $SchemaName")
            }
            else {
                $configText = "schema: $SchemaName$newLine$configText"
            }
            [IO.File]::WriteAllText($configPath, $configText)
            Write-Host "Selected schema '$SchemaName' in openspec/config.yaml"
        }

        Write-Host ''
        Write-Host "Installed $SchemaName $targetVersion ($targetRef) at $dest"
        if (-not $selectSchema) {
            Write-Host "To use it, set 'schema: $SchemaName' in openspec/config.yaml"
        }
        Write-Host 'Inspect the workflow with: openspec status'
    }
    finally {
        if ($cleanupWorkDir -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Installer
