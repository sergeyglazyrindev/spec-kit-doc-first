#!/usr/bin/env pwsh
<#
.SYNOPSIS
Docmost extension: fetch-docmost-page.ps1

Detects a Docmost page reference (a full page URL containing "/p/", or the
"docmost:<pageId>" shorthand) anywhere in a free-text input string, fetches
that page from the Docmost REST API (POST /api/pages/info, format=markdown)
plus its direct child pages (POST /api/pages/sidebar-pages, which filters by
parentPageId -- direct children only, not the full subtree), and prints one
JSON object to stdout.

Always exits 0 when no reference is found ({"matched":false}) so callers can
treat that as a harmless no-op. Exits 1 on any fetch failure once a reference
was recognized ({"matched":true,"error":"<code>","message":"<detail>"}).

Usage: fetch-docmost-page.ps1 [-Json] "<input text>"
(-Json is accepted for convention parity with other Spec Kit scripts; output
is always JSON.)
#>
param(
    [switch]$Json,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InputTextParts
)

$ErrorActionPreference = "Stop"
$InputText = if ($InputTextParts) { $InputTextParts[-1] } else { "" }
$MaxChildren = 20

function Emit-NoMatch {
    [PSCustomObject]@{ matched = $false } | ConvertTo-Json -Compress
    exit 0
}

function Emit-Error([string]$Code, [string]$Message) {
    [PSCustomObject]@{ matched = $true; error = $Code; message = $Message } | ConvertTo-Json -Compress
    exit 1
}

function Find-SpecifyRoot([string]$Start) {
    $dir = Resolve-Path -LiteralPath $Start | Select-Object -ExpandProperty Path
    while ($true) {
        if (Test-Path (Join-Path $dir ".specify") -PathType Container) {
            return $dir
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) {
            return $null
        }
        $dir = $parent
    }
}

function Read-ConfigValue([string]$Key, [string]$ConfigFile) {
    if (-not (Test-Path $ConfigFile -PathType Leaf)) { return "" }
    $pattern = "^\s*$([regex]::Escape($Key)):\s*(.*)\s*$"
    foreach ($line in Get-Content -LiteralPath $ConfigFile) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) {
            $value = $m.Groups[1].Value.Trim()
            if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and ($value[0] -eq '"' -or $value[0] -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return ""
}

function Get-FirstStringValue($Data, [string]$Key) {
    foreach ($path in @(@($Key), @("page", $Key), @("data", $Key))) {
        $node = $Data
        $ok = $true
        foreach ($k in $path) {
            if ($node -is [System.Collections.IDictionary] -and $node.Contains($k)) {
                $node = $node[$k]
            } elseif ($node -is [PSCustomObject] -and ($node.PSObject.Properties.Name -contains $k)) {
                $node = $node.$k
            } else {
                $ok = $false
                break
            }
        }
        if ($ok -and ($node -is [string])) { return $node }
    }
    return ""
}

# Shared HttpClient -- reused across the root fetch and any child fetches.
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$Client = [System.Net.Http.HttpClient]::new()
$Client.Timeout = [TimeSpan]::FromSeconds(30)

# Invoke-DocmostApi: POST $Path with $Payload (hashtable). Returns a
# PSCustomObject { Status, Data, Raw } -- Data is $null if the body wasn't
# valid JSON. Throws only on an actual network failure (DNS, connection
# refused, timeout), never on an HTTP error status -- callers check Status
# themselves, matching the bash/python variants' flow.
function Invoke-DocmostApi([string]$BaseUrl, [string]$Token, [string]$Path, [hashtable]$Payload) {
    $body = $Payload | ConvertTo-Json -Compress
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$BaseUrl$Path")
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
    $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    [PSCustomObject]@{ Status = [int]$response.StatusCode; Data = $data; Raw = $raw }
}

# Get-Children: best-effort fetch of direct children of $RootUuid. Any
# failure here just means no children are returned -- the root page fetch
# already succeeded and stands on its own.
function Get-Children([string]$BaseUrl, [string]$Token, [string]$RootUuid) {
    $result = [PSCustomObject]@{ Children = @(); Truncated = $false }
    try {
        $sidebar = Invoke-DocmostApi -BaseUrl $BaseUrl -Token $Token -Path "/api/pages/sidebar-pages" `
            -Payload @{ pageId = $RootUuid; limit = $MaxChildren }
    } catch {
        return $result
    }
    if ($sidebar.Status -lt 200 -or $sidebar.Status -ge 300 -or -not $sidebar.Data) {
        return $result
    }

    $items = @($sidebar.Data.items)
    $result.Truncated = [bool]$sidebar.Data.meta.hasNextPage

    $children = @()
    foreach ($item in $items) {
        $childId = $item.id
        $childTitle = if ($item.title) { $item.title } else { "" }
        if (-not $childId) { continue }
        try {
            $childResp = Invoke-DocmostApi -BaseUrl $BaseUrl -Token $Token -Path "/api/pages/info" `
                -Payload @{ pageId = $childId; format = "markdown" }
        } catch {
            continue
        }
        if ($childResp.Status -lt 200 -or $childResp.Status -ge 300 -or -not $childResp.Data) { continue }
        $childContent = Get-FirstStringValue $childResp.Data "content"
        if (-not $childContent) { continue }
        $children += [PSCustomObject]@{
            title     = $childTitle
            content   = $childContent
            pageId    = $childId
            sourceUrl = "$BaseUrl/p/$childId"
        }
    }
    $result.Children = $children
    return $result
}

# --- 1. Detect a Docmost reference anywhere in the input -------------------

$urlMatch = [regex]::Match($InputText, '(https?://[^\s"'']+)')
$candidateUrl = if ($urlMatch.Success) { $urlMatch.Groups[1].Value.TrimEnd(')', ']', ',', '.', '!', '?', '"', "'") } else { "" }

$matchKind = $null
$shorthandId = ""

if ($candidateUrl -and $candidateUrl.Contains("/p/")) {
    $matchKind = "url"
} else {
    $shorthandMatch = [regex]::Match($InputText, 'docmost:([A-Za-z0-9_-]+)')
    if ($shorthandMatch.Success) {
        $matchKind = "shorthand"
        $shorthandId = $shorthandMatch.Groups[1].Value
    }
}

if (-not $matchKind) { Emit-NoMatch }

# --- 2. Resolve pageId + base URL from the match ----------------------------

$pageId = ""
$baseUrl = ""
$sourceUrl = ""

if ($matchKind -eq "url") {
    $hostMatch = [regex]::Match($candidateUrl, '^(https?://[^/]+)')
    if ($hostMatch.Success) { $baseUrl = $hostMatch.Groups[1].Value }
    $afterP = $candidateUrl.Substring($candidateUrl.IndexOf("/p/") + 3)
    $segment = [regex]::Split($afterP, '[/?#]')[0]
    if ($segment.Contains("-")) {
        $pageId = $segment.Substring($segment.LastIndexOf("-") + 1)
    } else {
        $pageId = $segment
    }
    $sourceUrl = $candidateUrl
} else {
    $pageId = $shorthandId
}

if (-not $pageId) {
    Emit-Error "invalid_reference" "Found a Docmost reference but could not extract a page ID from it."
}

# --- 3. Load extension config (base_url default, token env var name) -------

$projectRoot = Find-SpecifyRoot (Get-Location).Path
$configFile = if ($projectRoot) {
    Join-Path $projectRoot ".specify/extensions/docmost/docmost-config.yml"
} else {
    "__no_project_root__"
}

if ($matchKind -eq "shorthand") {
    $baseUrl = Read-ConfigValue "base_url" $configFile
    if (-not $baseUrl) {
        Emit-Error "missing_base_url" "Set base_url in .specify/extensions/docmost/docmost-config.yml, or paste the full Docmost page URL instead of the docmost:<id> shorthand."
    }
}

$baseUrl = $baseUrl.TrimEnd('/')
if (-not $sourceUrl) { $sourceUrl = "$baseUrl/p/$pageId" }

$tokenEnv = Read-ConfigValue "api_token_env" $configFile
if (-not $tokenEnv) { $tokenEnv = "DOCMOST_API_TOKEN" }
if ($tokenEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    Emit-Error "invalid_config" "api_token_env in docmost-config.yml ('$tokenEnv') is not a valid environment variable name."
}

$token = [System.Environment]::GetEnvironmentVariable($tokenEnv)
if (-not $token) {
    Emit-Error "missing_token" "Set the `$$tokenEnv environment variable to a Docmost API token (create one in Docmost under Settings > API tokens)."
}

# --- 4. Fetch the root page --------------------------------------------------

try {
    $rootResp = Invoke-DocmostApi -BaseUrl $baseUrl -Token $token -Path "/api/pages/info" `
        -Payload @{ pageId = $pageId; format = "markdown" }
} catch {
    Emit-Error "network_error" "Could not reach $baseUrl`: $($_.Exception.Message)"
}

if ($rootResp.Status -lt 200 -or $rootResp.Status -ge 300) {
    $snippet = $rootResp.Raw.Substring(0, [Math]::Min(300, $rootResp.Raw.Length))
    Emit-Error "http_$($rootResp.Status)" "Docmost returned HTTP $($rootResp.Status)`: $snippet"
}

if (-not $rootResp.Data) {
    Emit-Error "invalid_response" "Docmost returned a response that was not valid JSON."
}

$title = Get-FirstStringValue $rootResp.Data "title"
$content = Get-FirstStringValue $rootResp.Data "content"
$rootUuid = Get-FirstStringValue $rootResp.Data "id"

if (-not $content) {
    Emit-Error "empty_content" "Docmost responded but no page content was found in the response body."
}

# --- 5. Fetch direct child pages (bounded, best-effort) ---------------------

$childrenResult = [PSCustomObject]@{ Children = @(); Truncated = $false }
if ($rootUuid) {
    $childrenResult = Get-Children -BaseUrl $baseUrl -Token $token -RootUuid $rootUuid
}

# --- 6. Emit the final result -----------------------------------------------

[PSCustomObject]@{
    matched           = $true
    title             = $title
    content           = $content
    pageId            = $pageId
    sourceUrl         = $sourceUrl
    fetchedAt         = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    children          = $childrenResult.Children
    childrenTruncated = $childrenResult.Truncated
} | ConvertTo-Json -Compress -Depth 6
