<#
.SYNOPSIS
Installs devlog-index.exe from a GitHub release into a per-user directory (no administrator rights).

.DESCRIPTION
Downloads the windows-x64 zip and SHA256SUMS of a release, checks the zip against its SHA256SUMS entry, and
copies devlog-index.exe into the install directory. On a checksum mismatch nothing is installed, the
download is removed, and the script exits 1 naming both hashes. Run it as a file (powershell -File
.\install.ps1): the failure exit code is not meaningful through `irm | iex`.

.PARAMETER Version
Release tag to install, such as v0.1.0. Defaults to the latest release.

.PARAMETER InstallDir
Where devlog-index.exe goes. Defaults to $env:LOCALAPPDATA\Programs\devlog-index.

.PARAMETER BaseUrl
Prefix that <Version>/<asset> is appended to. Defaults to the GitHub releases download URL; override it to
test against a local server. Requires -Version, since "latest" is resolved through the GitHub API.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir,
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Windows PowerShell 5.1 downloads crawl with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = 'emmz-makes-stuff/devlog-index'
$work = $null

try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'devlog-index is only built for 64-bit Windows.' }

    if (-not $InstallDir) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; pass -InstallDir.' }
        $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\devlog-index'
    }

    if (-not $Version) {
        if ($BaseUrl) { throw '-BaseUrl needs -Version; "latest" is only resolved against GitHub.' }
        $Version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
        if (-not $Version) { throw 'Could not work out the latest release.' }
    }
    if (-not $BaseUrl) { $BaseUrl = "https://github.com/$repo/releases/download" }

    $base = "$($BaseUrl.TrimEnd('/'))/$Version"
    $archive = "devlog-index-$Version-windows-x64.zip"
    $work = Join-Path ([IO.Path]::GetTempPath()) "devlog-index-install-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null

    Write-Host "Downloading $archive ($Version)"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$archive" -OutFile (Join-Path $work $archive)
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS')

    # sha256sum lines are "<hash>  <name>", or "<hash> *<name>" for binary mode.
    $expected = $null
    foreach ($line in Get-Content (Join-Path $work 'SHA256SUMS')) {
        if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -ceq $archive) { $expected = $Matches[1]; break }
    }
    if (-not $expected) { throw "SHA256SUMS has no entry for $archive." }

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $archive)).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        throw "Checksum mismatch for $archive`n  expected: $($expected.ToLowerInvariant())`n  actual:   $($actual.ToLowerInvariant())`nNothing was installed."
    }

    Expand-Archive -LiteralPath (Join-Path $work $archive) -DestinationPath (Join-Path $work 'x') -Force
    $exe = Join-Path $work 'x\devlog-index.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "$archive does not contain devlog-index.exe." }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $target = Join-Path $InstallDir 'devlog-index.exe'
    try {
        Copy-Item -LiteralPath $exe -Destination $target -Force
    } catch {
        throw "Could not write $target (is devlog-index running?): $($_.Exception.Message)"
    }
    Write-Host "Installed $target"

    $dirs = ($env:Path -split [IO.Path]::PathSeparator) | ForEach-Object { $_.TrimEnd('\', '/') }
    if ($dirs -contains $InstallDir.TrimEnd('\', '/')) {
        Write-Host "$InstallDir is on PATH."
    } else {
        Write-Host "$InstallDir is not on PATH. To add it for your account:"
        Write-Host "  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';$InstallDir', 'User')"
        Write-Host 'then open a new terminal.'
    }
} catch {
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
