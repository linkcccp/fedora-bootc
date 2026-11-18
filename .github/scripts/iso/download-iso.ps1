[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$OutputDir = (Get-Location).Path,
    [string]$Repo = "linkcccp/fedora-bootc",
    [switch]$KeepParts,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

$headers = @{
    "Accept"     = "application/vnd.github+json"
    "User-Agent" = "fedora-bootc-iso-downloader"
}
if ($env:GH_TOKEN) {
    $headers["Authorization"] = "Bearer $($env:GH_TOKEN)"
}

function Get-Release {
    if ($Version) {
        $tag = if ($Version -like "build-*") { $Version } else { "build-$Version" }
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag"
    }

    for ($page = 1; $page -le 5; $page++) {
        $releases = @(Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=100&page=$page")
        foreach ($release in $releases) {
            $hasIso = @($release.assets | Where-Object { $_.name -like "*.iso.part-00" }).Count -gt 0
            if ($hasIso) {
                return $release
            }
        }
    }

    Fail "no release with ISO parts found in $Repo"
}

function Download-File([string]$Url, [string]$Destination) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
            return
        } catch {
            if ($attempt -eq 3) {
                throw
            }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Get-ExpectedHash([string]$ChecksumFile) {
    $line = Get-Content -Path $ChecksumFile -TotalCount 1
    if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        Fail "invalid checksum file: $ChecksumFile"
    }
    return @{
        Hash = $matches[1].ToLowerInvariant()
        Name = $matches[2].Trim()
    }
}

function Test-Hash([string]$Path, [string]$Expected, [string]$Label) {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        Fail "checksum mismatch for ${Label}: expected $Expected, got $actual"
    }
}

$release = Get-Release
$tag = $release.tag_name
$assets = @($release.assets)
$parts = @($assets | Where-Object { $_.name -match '\.iso\.part-[0-9]+$' } | Sort-Object name)

if ($parts.Count -eq 0) {
    Fail "release $tag has no ISO parts"
}

$part00 = @($parts | Where-Object { $_.name -match '\.iso\.part-00$' } | Select-Object -First 1)
if ($part00.Count -eq 0) {
    Fail "release $tag has no .iso.part-00"
}

$isoName = $part00[0].name -replace '\.part-00$', ''
$isoShaName = "$isoName.sha256"
$partsShaAsset = @($assets | Where-Object { $_.name -eq "parts.sha256" } | Select-Object -First 1)
$isoShaAsset = @($assets | Where-Object { $_.name -eq $isoShaName } | Select-Object -First 1)

if ($partsShaAsset.Count -eq 0) {
    Fail "release $tag has no parts.sha256"
}
if ($isoShaAsset.Count -eq 0) {
    Fail "release $tag has no $isoShaName"
}

$out = (New-Item -ItemType Directory -Force -Path $OutputDir).FullName
$free = $null
try {
    $drive = (Get-Item $out).PSDrive.Name
    $free = (Get-PSDrive -Name $drive).Free
} catch {
    Write-Warning "could not determine free disk space: $($_.Exception.Message)"
}
if ($null -ne $free) {
    $need = if ($KeepParts) { 26GB } else { 14GB }
    if ($free -lt $need -and -not $Force) {
        Fail ("need about {0:N0} GiB free in {1}, only {2:N0} GiB available (use -Force to continue)" -f ($need / 1GB), $out, ($free / 1GB))
    }
}

Write-Host "Release: $tag"
Write-Host "ISO:     $isoName"
Write-Host "Parts:   $($parts.Count)"

Download-File -Url $partsShaAsset[0].browser_download_url -Destination (Join-Path $out "parts.sha256")
Download-File -Url $isoShaAsset[0].browser_download_url -Destination (Join-Path $out $isoShaName)

foreach ($part in $parts) {
    Write-Host "Downloading $($part.name)"
    Download-File -Url $part.browser_download_url -Destination (Join-Path $out $part.name)
}

$verified = 0
foreach ($line in Get-Content -Path (Join-Path $out "parts.sha256")) {
    if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        continue
    }
    $expected = $matches[1].ToLowerInvariant()
    $name = $matches[2].Trim()
    Test-Hash -Path (Join-Path $out $name) -Expected $expected -Label $name
    $verified++
}
if ($verified -eq 0) {
    Fail "parts.sha256 did not contain any checksums"
}

$isoPath = Join-Path $out $isoName
if (Test-Path $isoPath) {
    Remove-Item -Path $isoPath -Force
}

$outStream = [System.IO.File]::Open($isoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    foreach ($part in $parts) {
        $partPath = Join-Path $out $part.name
        $inStream = [System.IO.File]::OpenRead($partPath)
        try {
            $inStream.CopyTo($outStream)
        } finally {
            $inStream.Dispose()
        }
        if (-not $KeepParts) {
            Remove-Item -Path $partPath -Force
        }
    }
} finally {
    $outStream.Dispose()
}

$isoHash = Get-ExpectedHash -ChecksumFile (Join-Path $out $isoShaName)
Test-Hash -Path $isoPath -Expected $isoHash.Hash -Label $isoName

Write-Host ""
Write-Host "ISO ready: $isoPath"
Write-Host ("Size:      {0:N2} GiB" -f ((Get-Item $isoPath).Length / 1GB))
if (-not $KeepParts) {
    Write-Host "Parts were deleted; use -KeepParts to keep them."
}
