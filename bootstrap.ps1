# zellij-terminal one-liner installer.
#
# Usage:
#   irm https://raw.githubusercontent.com/ztpwsh/zellij-terminal/main/bootstrap.ps1 | iex
#
# What it does:
#   1. Verifies PowerShell 7+ and git.
#   2. Clones (or updates) the repo.
#   3. Runs install.ps1 from the clone, which junctions the module, writes
#      Zellij's config and layout, and registers the Claude Code hook.
#
# To install somewhere other than the default, clone by hand and run
# install.ps1 directly - `iex` gives no way to pass arguments.

$ErrorActionPreference = 'Stop'

# #Requires is only honoured when a script is INVOKED. iex executes the body as
# a string, so the version has to be checked at runtime or a 5.1 user gets a
# parse error instead of an explanation.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'zellij-terminal needs PowerShell 7 or later.' -ForegroundColor Red
    Write-Host "You are running PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'The module is installed to the pwsh 7 module path, so 5.1 cannot' -ForegroundColor Yellow
    Write-Host 'autoload it. Open a PowerShell 7 tab and retry, or install it:' -ForegroundColor Yellow
    Write-Host '  winget install --id Microsoft.PowerShell' -ForegroundColor Cyan
    Write-Host ''
    return
}

# The one place the published location is written down. Stamp it before you
# publish - tools\Set-RepoOwner.ps1 does every file at once - or override it for
# a fork without editing anything:
#     $env:ZT_REPO_URL = 'https://github.com/me/zellij-terminal.git'; irm ... | iex
#
# The example above deliberately says 'me' rather than the placeholder: once the
# repo is stamped, grepping for the placeholder should return nothing at all, and
# an example that still contained it would make that check useless.
$repoUrl = $env:ZT_REPO_URL
if (-not $repoUrl) { $repoUrl = 'https://github.com/ztpwsh/zellij-terminal.git' }

# Refuse loudly rather than cloning a repo that cannot exist. An unstamped
# placeholder reaching a user is the failure this project keeps re-learning:
# git would report "repository not found", which reads as the repo being private
# or deleted rather than as this file never having been finished.
if ($repoUrl -match '/OWNER/') {
    throw ('This copy of bootstrap.ps1 has not been stamped with a repository owner. ' +
           'Run tools\Set-RepoOwner.ps1 <owner> in the clone before publishing, or set ' +
           '$env:ZT_REPO_URL to clone from your own fork.')
}

$dest = Join-Path $HOME 'zellij-terminal'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required and not on PATH. Install it (winget install Git.Git), reopen PowerShell, then retry.'
}

# Said here, before the clone, and only when it is actually true. This used to
# be an unconditional Write-Host at the very end - printed after install.ps1 had
# finished, so it arrived too late to act on, and printed to people who already
# had Zellij. install.ps1 does the real check and offers to run winget; this is
# just the earliest possible warning, while you are still watching the output.
if (-not (Get-Command zellij -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  Zellij is not on PATH yet - needs 0.44+ for native Windows.' -ForegroundColor Yellow
    Write-Host '  The installer will offer to fetch it with winget.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  zellij-terminal' -ForegroundColor Cyan
Write-Host ''

if (Test-Path -LiteralPath $dest) {
    Write-Host "  Already cloned at $dest - updating..." -ForegroundColor Cyan
    Push-Location $dest
    try {
        # git writes ordinary progress to stderr; let it through rather than
        # letting PowerShell dramatise it as an error.
        git pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git pull failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Cloning to $dest..." -ForegroundColor Cyan
    git clone --depth 1 $repoUrl $dest
    if ($LASTEXITCODE -ne 0) { throw "git clone failed ($LASTEXITCODE)" }
}

# Hand off to the real installer, which knows about junctions, Zellij's config
# directory and the hook template.
& (Join-Path $dest 'install.ps1')

# install.ps1 sets a non-zero exit code deliberately, and says why in its own
# closing comment: "bootstrap.ps1 printing 'keep the clone' after a failed
# install was the visible symptom". This was the link that still did not read
# it - the two git calls above are both checked, and the one step that can
# half-succeed was not.
if ($LASTEXITCODE -ne 0) {
    throw ("install.ps1 failed ($LASTEXITCODE) - the problems are printed above. " +
           "The clone at $dest is intact; fix what it named and re-run install.ps1 there.")
}

Write-Host "  The clone is at $dest - keep it; the module is junctioned to it." -ForegroundColor DarkGray
Write-Host ''
