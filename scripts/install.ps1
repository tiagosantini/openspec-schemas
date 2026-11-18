#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
Install or update the prototype-first OpenSpec schema in the current project.

.DESCRIPTION
The schema is installed into ./openspec/schemas/prototype-first and selected in
./openspec/config.yaml. Run from an OpenSpec project root, or pass -Dir.

Remote:
  irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1 | iex

Pass options remotely with a script block:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/scripts/install.ps1))) -NoSelect

Local (from a clone of this repository):
  ./scripts/install.ps1
#>
[CmdletBinding()]
param(
    [string]$Dir,
    [string]$BaseUrl,
    [switch]$Select,
    [switch]$NoSelect,
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
$DefaultBaseUrl = "https://raw.githubusercontent.com/tiagosantini/openspec-schemas/main/schemas/$SchemaName"
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
    param([string]$Message)
    if ($PSScriptRoot) {
        [Console]::Error.WriteLine("error: $Message")
        exit 1
    }
    throw "error: $Message"
}

function Show-Usage {
    @"
Install or update the $SchemaName OpenSpec schema.

Usage:
  scripts/install.ps1 [options]

Options:
  -Dir <path>    Project root to install into (default: current directory)
  -BaseUrl <url> Base URL to download the schema from
  -Select        Select the schema in openspec/config.yaml (default)
  -NoSelect      Leave openspec/config.yaml unchanged
  -Help          Show this help

Environment:
  SCHEMA_BASE_URL    Base URL to download the schema from
  SCHEMA_TARGET_DIR  Project root (same as -Dir)

The script uses the local schemas/$SchemaName directory when run from a
checkout of this repository. Otherwise it downloads the schema from
SCHEMA_BASE_URL.
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
    if (-not $BaseUrl) {
        $BaseUrl = $env:SCHEMA_BASE_URL
    }
    if (-not $BaseUrl) {
        $BaseUrl = $DefaultBaseUrl
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

    if (-not (Test-Path -LiteralPath $openspecDir -PathType Container)) {
        Fail "no openspec/ directory in $targetDir. Run 'openspec init' first, or pass -Dir <project-root>"
    }
    if ($selectSchema -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Fail "openspec/config.yaml not found in $targetDir. Run 'openspec init' first, or pass -NoSelect"
    }

    # Prefer the checkout this script belongs to. When piped through iex,
    # $PSScriptRoot is empty and the schema is downloaded instead.
    $localSource = $null
    if ($PSScriptRoot) {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $candidate = Join-Path (Join-Path $repoRoot 'schemas') $SchemaName
        if (Test-Path -LiteralPath (Join-Path $candidate 'schema.yaml') -PathType Leaf) {
            $localSource = $candidate
        }
    }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("$SchemaName." + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $stage = Join-Path $workDir $SchemaName
    $backup = $null
    $cleanupWorkDir = $true

    try {
        if ($localSource) {
            Write-Host "Installing from $localSource"
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Get-ChildItem -LiteralPath $localSource -Force |
                Copy-Item -Destination $stage -Recurse -Force
        }
        else {
            Write-Host "Downloading from $BaseUrl"
            foreach ($file in $Files) {
                $destFile = Join-Path $stage $file
                $parent = Split-Path -Parent $destFile
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Invoke-Download -Uri "$BaseUrl/$file" -OutFile $destFile
            }
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
            $backup = Join-Path $workDir 'previous'
            Write-Host "Replacing existing installation at $dest"
            Move-Item -LiteralPath $dest -Destination $backup
        }

        try {
            Move-Item -LiteralPath $stage -Destination $dest

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
                        throw "schema validation failed; previous installation restored"
                    }
                    throw "schema validation failed"
                }
                Write-Host "Validated schema '$SchemaName'"
            }
            else {
                Write-Warning 'openspec CLI not found; skipped validation'
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
        Write-Host "Installed $SchemaName at $dest"
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
