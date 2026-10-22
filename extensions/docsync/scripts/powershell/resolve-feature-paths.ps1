#!/usr/bin/env pwsh

# Resolve the active feature's artifact paths for the docsync extension.
#
# Deliberately self-contained: the docsync extension owns this script rather
# than depending on core's check-prerequisites.ps1, so speckit.docsync.usespec
# and speckit.docsync.refreshspec keep working regardless of core's command
# set. It is a trimmed twin of core check-prerequisites.ps1's -PathsOnly mode
# -- it resolves the project root and the active feature directory and
# reports every artifact path next to it, without requiring any of them to
# exist (paths-only resolution performs no validation; callers decide what a
# missing file means for them).
#
# Usage: ./resolve-feature-paths.ps1 [-Json]
#
# OPTIONS:
#   -Json       Output in JSON format
#   -Help       Show help message

[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$PathsOnly,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Write-Output @"
Usage: resolve-feature-paths.ps1 [OPTIONS]

Resolve the active feature's artifact paths for the docsync extension.

OPTIONS:
  -Json       Output in JSON format
  -Help       Show this help message

EXAMPLES:
  ./resolve-feature-paths.ps1 -Json
"@
    exit 0
}

# Find the project root by searching upward for the .specify marker directory.
function Find-SpecifyRoot {
    param([string]$StartDir = (Get-Location).Path)

    $resolved = Resolve-Path -LiteralPath $StartDir -ErrorAction SilentlyContinue
    $current = if ($resolved) { $resolved.Path } else { $null }
    if (-not $current) { return $null }

    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $current ".specify") -PathType Container) {
            return $current
        }
        $parent = Split-Path $current -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            return $null
        }
        $current = $parent
    }
}

# Resolve the project root, honouring an explicit SPECIFY_INIT_DIR override.
# Mirrors core Get-RepoRoot: strict on an invalid override, no silent fallback.
function Get-ProjectRoot {
    if ($env:SPECIFY_INIT_DIR) {
        $initDir = $env:SPECIFY_INIT_DIR
        if (-not [System.IO.Path]::IsPathRooted($initDir)) {
            $initDir = Join-Path (Get-Location).Path $initDir
        }
        $resolved = Resolve-Path -LiteralPath $initDir -ErrorAction SilentlyContinue
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
            [Console]::Error.WriteLine("ERROR: SPECIFY_INIT_DIR does not point to an existing directory: $($env:SPECIFY_INIT_DIR)")
            exit 1
        }
        $initRoot = $resolved.Path.TrimEnd('/', '\')
        if ($initRoot.Length -lt [System.IO.Path]::GetPathRoot($resolved.Path).Length) {
            $initRoot = $resolved.Path
        }
        if (-not (Test-Path -LiteralPath (Join-Path $initRoot '.specify') -PathType Container)) {
            [Console]::Error.WriteLine("ERROR: SPECIFY_INIT_DIR is not a Spec Kit project (no .specify/ directory): $initRoot")
            exit 1
        }
        return $initRoot
    }

    $specifyRoot = Find-SpecifyRoot
    if ($specifyRoot) { return $specifyRoot }

    # Installed scripts live at .specify/extensions/docsync/scripts/powershell/.
    $fromScript = Find-SpecifyRoot -StartDir $PSScriptRoot
    if ($fromScript) { return $fromScript }

    [Console]::Error.WriteLine("ERROR: Not inside a Spec Kit project (no .specify/ directory found).")
    exit 1
}

# Persist a feature_directory value to .specify/feature.json.
# Writes only when the file is missing or the stored value differs.
# Mirrors core's Save-FeatureJson (scripts/powershell/common.ps1).
function Save-FeatureJson {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$FeatureDirectory
    )

    $prefix = $RepoRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($null -ne $IsWindows) { $onWin = $IsWindows } else { $onWin = $true }
    if ($onWin) {
        $cmp = [System.StringComparison]::OrdinalIgnoreCase
    } else {
        $cmp = [System.StringComparison]::Ordinal
    }
    if ($FeatureDirectory.StartsWith($prefix, $cmp)) {
        $FeatureDirectory = $FeatureDirectory.Substring($prefix.Length)
    }

    $fjPath = Join-Path (Join-Path $RepoRoot '.specify') 'feature.json'

    if (Test-Path -LiteralPath $fjPath -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($fjPath, [System.Text.Encoding]::UTF8)
            $cfg = $raw | ConvertFrom-Json
            if ($cfg.feature_directory -eq $FeatureDirectory) {
                return
            }
        } catch {
            # File is corrupt or unreadable - overwrite it.
        }
    }

    $specifyDir = Join-Path $RepoRoot '.specify'
    if (-not (Test-Path -LiteralPath $specifyDir -PathType Container)) {
        New-Item -ItemType Directory -Path $specifyDir -Force | Out-Null
    }

    $json = @{ feature_directory = $FeatureDirectory } | ConvertTo-Json -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fjPath, $json, $utf8NoBom)
}

$repoRoot = Get-ProjectRoot

# Resolve the feature directory. Priority:
#   1. SPECIFY_FEATURE_DIRECTORY (explicit override)
#   2. .specify/feature.json "feature_directory"
# No feature on record is a distinct, recognizable failure (this exact
# message) so callers such as speckit.docsync.usespec can treat "no current
# feature yet" as a branch to handle rather than a hard stop.
$featureJson = Join-Path $repoRoot '.specify/feature.json'
if ($env:SPECIFY_FEATURE_DIRECTORY) {
    $featureDir = $env:SPECIFY_FEATURE_DIRECTORY
    if ($env:SPECIFY_FEATURE_NO_PERSIST -ne '1' -and $env:SPECIFY_FEATURE_NO_PERSIST -ne 'true') {
        Save-FeatureJson -RepoRoot $repoRoot -FeatureDirectory $env:SPECIFY_FEATURE_DIRECTORY
    }
} elseif (Test-Path -LiteralPath $featureJson -PathType Leaf) {
    $featureJsonRaw = [System.IO.File]::ReadAllText($featureJson, [System.Text.Encoding]::UTF8)
    try {
        $featureConfig = $featureJsonRaw | ConvertFrom-Json
    } catch {
        [Console]::Error.WriteLine("ERROR: No current feature on record. Set SPECIFY_FEATURE_DIRECTORY, or run the Spec Kit specify command (or speckit.docsync.usespec) to create .specify/feature.json.")
        exit 1
    }
    if ($featureConfig.feature_directory) {
        $featureDir = $featureConfig.feature_directory
    } else {
        [Console]::Error.WriteLine("ERROR: No current feature on record. Set SPECIFY_FEATURE_DIRECTORY, or run the Spec Kit specify command (or speckit.docsync.usespec) to create .specify/feature.json.")
        exit 1
    }
} else {
    [Console]::Error.WriteLine("ERROR: No current feature on record. Set SPECIFY_FEATURE_DIRECTORY, or run the Spec Kit specify command (or speckit.docsync.usespec) to create .specify/feature.json.")
    exit 1
}

if (-not [System.IO.Path]::IsPathRooted($featureDir)) {
    $featureDir = Join-Path $repoRoot $featureDir
}

if (-not (Test-Path -LiteralPath $featureDir -PathType Container)) {
    [Console]::Error.WriteLine("ERROR: Feature directory not found: $featureDir")
    [Console]::Error.WriteLine("Run the Spec Kit specify command (or speckit.docsync.usespec) first to create the feature structure.")
    exit 1
}

$featureSpec = Join-Path $featureDir 'spec.md'
$implPlan = Join-Path $featureDir 'plan.md'
$tasks = Join-Path $featureDir 'tasks.md'
$research = Join-Path $featureDir 'research.md'
$dataModel = Join-Path $featureDir 'data-model.md'
$quickstart = Join-Path $featureDir 'quickstart.md'
$contractsDir = Join-Path $featureDir 'contracts'

if ($Json) {
    $payload = [ordered]@{
        REPO_ROOT     = $repoRoot
        FEATURE_DIR   = $featureDir
        FEATURE_SPEC  = $featureSpec
        IMPL_PLAN     = $implPlan
        TASKS         = $tasks
        RESEARCH      = $research
        DATA_MODEL    = $dataModel
        QUICKSTART    = $quickstart
        CONTRACTS_DIR = $contractsDir
    }
    Write-Output ($payload | ConvertTo-Json -Compress)
} else {
    Write-Output "REPO_ROOT:$repoRoot"
    Write-Output "FEATURE_DIR:$featureDir"
    Write-Output "FEATURE_SPEC:$featureSpec"
    Write-Output "IMPL_PLAN:$implPlan"
    Write-Output "TASKS:$tasks"
    Write-Output "RESEARCH:$research"
    Write-Output "DATA_MODEL:$dataModel"
    Write-Output "QUICKSTART:$quickstart"
    Write-Output "CONTRACTS_DIR:$contractsDir"
}
