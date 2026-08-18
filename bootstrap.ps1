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

# The upgrade path nobody designed for, and the one everybody takes: you are
# working in the session, you read that a new version is out, you paste the
# one-liner into the pane in front of you. It works - nesting is not blocked -
# but the zjstatus permission grant cannot be written while a Zellij server is
# running, and the server it means is the one you are typing in. So the upgrade
# completes and the machine still has no status bar.
#
# Said HERE as well as in install.ps1, before anything is cloned, because this
# is the earliest point at which opening a different window is still free.
# Report only: refusing would be worse than the warning, and this script has no
# business deciding that for you.
if ($env:ZELLIJ) {
    $zjName = $env:ZELLIJ_SESSION_NAME
    if (-not $zjName) { $zjName = '(unknown)' }
    Write-Host ''
    Write-Host "  You are inside Zellij session '$zjName'." -ForegroundColor Yellow
    Write-Host '  The install will run, but the zjstatus permission grant cannot be' -ForegroundColor Yellow
    Write-Host '  written while a session is up - and that includes this one. Running' -ForegroundColor Yellow
    Write-Host '  this from an ordinary PowerShell window avoids the extra steps.' -ForegroundColor Yellow
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
        git fetch origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed ($LASTEXITCODE)" }

        # Whatever this clone is actually on, rather than assuming 'main' - a
        # fork may publish from somewhere else.
        $branch = (git symbolic-ref --short HEAD)
        if ($LASTEXITCODE -ne 0 -or -not $branch) { $branch = 'main' }
        $branch = $branch.Trim()

        git merge --ff-only "origin/$branch"
        if ($LASTEXITCODE -ne 0) {
            # THIS REPOSITORY'S HISTORY IS REBUILT, NOT APPENDED TO. It is
            # generated output: tools/Publish-Release.ps1 rewrites the branch
            # from a manifest and force-pushes it whenever a published blob has
            # to stop being recoverable. An older clone then has genuinely
            # unrelated history and can NEVER fast-forward again, so
            # `git pull --ff-only` failed here permanently and told the user
            # only "Not possible to fast-forward, aborting" - which reads as a
            # bug in their clone rather than as the expected consequence of a
            # rebuild. Reported from a real machine stuck on f28fccb.
            #
            # Resetting is the honest thing: nobody should be editing this
            # clone, it is an install source. But check first, because "nobody
            # should" is not "nobody does", and config/workspaces.json is a
            # tracked file people do reasonably edit.
            $dirty = @(git status --porcelain --untracked-files=no | Where-Object { $_ })
            if ($dirty.Count -gt 0) {
                throw ("The published history was rebuilt, so this clone cannot be updated in place, " +
                       "and it has $($dirty.Count) local change(s) that a reset would destroy:`n" +
                       ($dirty -join "`n") + "`n`n" +
                       "Move them somewhere safe, then re-run this. Or, to discard them: `n" +
                       "  git -C $dest reset --hard origin/$branch")
            }

            Write-Host '  Published history was rebuilt - resetting the clone to match.' -ForegroundColor Yellow
            git reset --hard "origin/$branch"
            if ($LASTEXITCODE -ne 0) { throw "git reset --hard origin/$branch failed ($LASTEXITCODE)" }

            # Deliberately no `git clean`. A clone from before 0.6 can still
            # hold config/devices/<HOST>.json - a real device registry, now
            # untracked because that file moved to %LOCALAPPDATA% - and
            # deleting a registry to tidy up a checkout is not a trade this
            # script gets to make. A stale untracked file is harmless; nothing
            # reads it.
        }
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
if ($LASTEXITCODE -eq 2) {
    # 2 is "installed, one step deferred" - see install.ps1's closing banner.
    # It is deliberately not 1: on every machine upgrading from 0.7.9 or earlier
    # while it is in use, the permission grant defers, and throwing here told
    # those users their install had FAILED. It had not; one step needed them to
    # close their sessions first, and the sequence for doing that without losing
    # anything was printed by the installer a few lines up. Reporting a working
    # machine as broken invites the one response that cannot help - running the
    # installer again with the server still up.
    Write-Host ''
    Write-Host '  Installed, with a step deferred - the sequence to finish it is above.' -ForegroundColor Yellow
} elseif ($LASTEXITCODE -ne 0) {
    throw ("install.ps1 failed ($LASTEXITCODE) - the problems are printed above. " +
           "The clone at $dest is intact; fix what it named and re-run install.ps1 there.")
}

Write-Host "  The clone is at $dest - keep it; the module is junctioned to it." -ForegroundColor DarkGray
Write-Host ''
