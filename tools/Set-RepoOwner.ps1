<#
.SYNOPSIS
    Stamp the published repository owner into every file that references it.

.DESCRIPTION
    The repo ships anonymised: the GitHub owner appears as the literal OWNER, in
    the installer, the README and the module manifest. That is deliberate - a
    public product should not carry its author's handle around - but a
    placeholder that reaches a user is its own failure, so nothing is left to
    chance:

      * bootstrap.ps1 refuses to run while OWNER is unstamped
      * Placeholders.Tests.ps1 fails the build if one escapes
      * this script does all of them at once, so there is no list to remember

    Idempotent. Run it again after a fork, or with -Revert to hand the tree back
    to its anonymous state before opening a pull request.

.EXAMPLE
    .\tools\Set-RepoOwner.ps1 acme-corp
    .\tools\Set-RepoOwner.ps1 -Revert
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Set')]
param(
    # The GitHub user or organisation the repo is published under.
    [Parameter(ParameterSetName = 'Set', Mandatory = $true, Position = 0)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}$')]
    [string]$Owner,

    # Put OWNER back, so the tree is publishable as a template again.
    [Parameter(ParameterSetName = 'Revert', Mandatory = $true)]
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# Every file that names the owner. Kept here rather than discovered by scanning,
# so adding a reference somewhere new is a deliberate act that updates this list
# - a scan would silently start covering files nobody meant to templatise.
$targets = @(
    'bootstrap.ps1'
    'README.md'
    'module/ZellijTerminal/ZellijTerminal.psd1'
)

if ($Revert) { $from = $null; $to = 'OWNER' }
else         { $from = 'OWNER'; $to = $Owner }

$changed = 0
$wouldChange = 0
foreach ($rel in $targets) {
    $path = Join-Path $repo $rel
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "Not found, skipping: $rel"
        continue
    }

    $text = Get-Content -LiteralPath $path -Raw
    $orig = $text

    if ($Revert) {
        # Match the owner segment structurally rather than by remembering what
        # it was last set to, so a tree stamped by somebody else still reverts.
        $text = [regex]::Replace($text, '(github\.com/)[A-Za-z0-9][A-Za-z0-9-]{0,38}(/zellij-terminal)', "`${1}OWNER`${2}")
        $text = [regex]::Replace($text, '(githubusercontent\.com/)[A-Za-z0-9][A-Za-z0-9-]{0,38}(/zellij-terminal)', "`${1}OWNER`${2}")
    } else {
        $text = $text.Replace("github.com/$from/zellij-terminal", "github.com/$to/zellij-terminal")
        $text = $text.Replace("githubusercontent.com/$from/zellij-terminal", "githubusercontent.com/$to/zellij-terminal")
    }

    if ($text -ne $orig) {
        # Counted separately from $changed. Under -WhatIf nothing is written, so
        # reporting "already set - nothing to do" would be a flat lie about a
        # tree that is still unstamped, which is the exact failure this script
        # exists to prevent.
        $wouldChange++
        if ($PSCmdlet.ShouldProcess($rel, "Set owner to $to")) {
            Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
            Write-Host "  $rel" -ForegroundColor DarkGray
            $changed++
        }
    }
}

Write-Host ''
if ($changed -gt 0) {
    Write-Host "  Owner set to '$to' in $changed file(s)." -ForegroundColor Green
} elseif ($wouldChange -gt 0) {
    Write-Host "  Would set owner to '$to' in $wouldChange file(s). Nothing written." -ForegroundColor Yellow
} else {
    Write-Host "  Already set to '$to' - nothing to do." -ForegroundColor DarkGray
}
Write-Host ''
