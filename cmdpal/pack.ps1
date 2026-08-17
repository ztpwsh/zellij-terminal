<#
.SYNOPSIS
    Publish, package, sign and install the Command Palette extension.

.DESCRIPTION
    There is no template and no single-project MSIX here, so this does the four
    steps by hand:

      1. dotnet publish, self-contained - the package must not depend on a
         .NET runtime being installed at the right version
      2. makeappx pack        - folder -> .msix
      3. signtool sign        - self-signed; developer mode allows the install,
                                but Windows still requires a signature
      4. Add-AppxPackage

    The certificate subject MUST equal the manifest's Publisher exactly
    ("CN=ZellijTerminal"), or Add-AppxPackage rejects the package with an error
    about the publisher not matching.

.EXAMPLE
    .\pack.ps1
    .\pack.ps1 -SkipInstall
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$proj    = Join-Path $root 'ZellijTerminal.Palette'
$stage   = Join-Path $root 'staging'
$out     = Join-Path $root 'out'
$msix    = Join-Path $out 'ZellijTerminal.Palette.msix'
$subject = 'CN=ZellijTerminal'

function Get-SdkTool {
    param([string]$Name)
    $bins = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^10\.' } | Sort-Object Name -Descending
    foreach ($b in $bins) {
        $p = Join-Path $b.FullName (Join-Path 'x64' $Name)
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "$Name not found in any Windows Kits bin directory."
}

$makeappx = Get-SdkTool 'makeappx.exe'
$signtool = Get-SdkTool 'signtool.exe'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    $env:PATH = "C:\Program Files\dotnet;$env:PATH"
}

# --- 1. publish -------------------------------------------------------------
Write-Host '[1/4] publishing...' -ForegroundColor Cyan
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

& dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
    -p:Platform=x64 -p:PublishSingleFile=false -o $stage | Out-Null
if ($LASTEXITCODE -ne 0) { throw "publish failed ($LASTEXITCODE)" }

# Every pack gets a new version, or Add-AppxPackage refuses with 0x80073CFB:
# "same identity as an already-installed package but the contents are
# different". Without this, the edit-build-install loop needs a manual bump or
# an uninstall every single time, which is the difference between iterating and
# not bothering.
#
# Build = days since 2026-01-01, Revision = minutes since midnight. Monotonic,
# and both stay inside the 0-65535 each component allows.
$manifestPath = Join-Path $stage 'AppxManifest.xml'
Copy-Item (Join-Path $proj 'Package.appxmanifest') $manifestPath -Force

$now      = Get-Date
$buildNum = [int]($now.Date - [datetime]'2026-01-01').TotalDays
$revNum   = [int]($now.TimeOfDay.TotalMinutes)
$version  = "0.1.$buildNum.$revNum"

$xml = Get-Content $manifestPath -Raw
$xml = [regex]::Replace($xml, '(<Identity[^>]*Version=")[^"]+(")', "`${1}$version`${2}")
Set-Content -LiteralPath $manifestPath -Value $xml -Encoding UTF8
Write-Host "  version $version" -ForegroundColor DarkGray
Copy-Item (Join-Path $proj 'Assets') (Join-Path $stage 'Assets') -Recurse -Force

# PublicFolder in the manifest must exist, even when empty, or the package is
# rejected at install with a vague manifest error.
New-Item -ItemType Directory -Path (Join-Path $stage 'Public') -Force | Out-Null

# --- 2. pack ----------------------------------------------------------------
Write-Host '[2/4] packing...' -ForegroundColor Cyan
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
if (Test-Path $msix) { Remove-Item $msix -Force }

& $makeappx pack /d $stage /p $msix /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }

# --- 3. sign ----------------------------------------------------------------
Write-Host '[3/4] signing...' -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject } | Select-Object -First 1
if (-not $cert) {
    Write-Host "  creating a self-signed certificate for $subject" -ForegroundColor DarkGray
    $cert = New-SelfSignedCertificate -Type Custom -Subject $subject `
        -KeyUsage DigitalSignature -FriendlyName 'ZellijTerminal Palette (dev)' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')

    # Windows will not trust a signature from a certificate it does not know,
    # so the same cert has to land in TrustedPeople. That store is machine-wide
    # and needs elevation - hence the explicit message rather than a failure
    # three steps later at install time.
    $tmp = Join-Path $env:TEMP 'zt-cmdpal-dev.cer'
    Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
    Write-Host ''
    Write-Host '  The certificate must be trusted before the package will install.' -ForegroundColor Yellow
    Write-Host '  Run this ONCE in an elevated PowerShell:' -ForegroundColor Yellow
    Write-Host "    Import-Certificate -FilePath '$tmp' -CertStoreLocation Cert:\LocalMachine\TrustedPeople" -ForegroundColor White
    Write-Host ''
}

& $signtool sign /fd SHA256 /a /sha1 $cert.Thumbprint $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }

Write-Host "  signed: $msix" -ForegroundColor DarkGray

# --- 4. install -------------------------------------------------------------
if ($SkipInstall) { Write-Host '[4/4] skipped.' -ForegroundColor DarkGray; return }

Write-Host '[4/4] installing...' -ForegroundColor Cyan

# Command Palette keeps the extension's COM server running, and Windows refuses
# to replace a package whose files are in use (0x80073D02, "the following apps
# need to be closed"). Stopping it is safe - the palette restarts it on demand.
$running = @(Get-Process 'ZellijTerminal.Palette' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host "  stopping $($running.Count) running instance(s)" -ForegroundColor DarkGray
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

try {
    Add-AppxPackage -Path $msix -ForceUpdateFromAnyVersion -ErrorAction Stop
    Write-Host ''
    Write-Host '  Installed. Restart Command Palette (Win+Alt+Space) to pick it up.' -ForegroundColor Green
    Write-Host ''
} catch {
    Write-Host ''
    Write-Warning "Install failed: $($_.Exception.Message)"
    Write-Host '  If it mentions the certificate, import it into LocalMachine\TrustedPeople (see above).' -ForegroundColor DarkGray
    Write-Host ''
    throw
}



