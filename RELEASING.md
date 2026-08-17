# Releasing

There is no build artefact here. Installing means cloning the repo and running
`install.ps1`, so a release is nothing more than: `main` is a commit a stranger
can run. The steps are in order because each depends on the one before it, and
each says what breaks if you skip it.

## 1. Stamp the owner

```powershell
.\tools\Set-RepoOwner.ps1 acme-corp
```

Three files name the GitHub owner as an upper-case placeholder: `bootstrap.ps1`
(the clone URL), `README.md` (the `irm` one-liner and the links) and
`module/ZellijTerminal/ZellijTerminal.psd1` (`ProjectUri`, `LicenseUri`). The
script does all three at once, so there is no list to remember. This document
deliberately does not spell the placeholder out - `Placeholders.Tests.ps1` fails
any tracked file outside those three that contains it, including this one.

Skip it and `bootstrap.ps1` throws before it clones: it matches its own resolved
URL against the placeholder segment on purpose, because git reports "repository
not found" for a URL that still carries it, which reads as the repo being
private or deleted rather than as the file never having been finished. The
README one-liner and the manifest URIs carry no such guard - they just 404.

`bootstrap.ps1` still contains the placeholder after stamping; that is the
guard's own pattern, and the test allows it there. `-Revert` hands the tree back
to its anonymous state, which is what you want before opening a pull request.

A clone of the published repository is already stamped, so this step is for a
fork that will install from its own URL.

## 2. Run the suite and the analyzer gate

```powershell
Import-Module Pester -MinimumVersion 6.0.0 -MaximumVersion 6.9999.9999 -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = './tests'
Invoke-Pester -Configuration $cfg
```

On pwsh 7.6 with Pester 6.1 and PSScriptAnalyzer 1.25 this is 313 passed, 0
skipped. The count moves as tests are added; what matters is that nothing is
red and nothing is skipped for a reason nobody has looked at. The reference
check was once `-Skip` with real dangling references named in its comment - the
references were fixed and the skip removed, which is the only honest ending for
a test skipped over a defect. A skip that outlives its cause reads exactly like
a pass.

Assertions that need a session, a git identity, PSScriptAnalyzer or a real
Windows PowerShell guard themselves, so a green run on a machine without the rig
is expected rather than suspicious.

Read what the analyzer printed, not just the tick. `tests/Analyzer.Tests.ps1`
skips its whole Describe when PSScriptAnalyzer is absent, so a machine without
it reports green having gated nothing. A real run prints
`PSScriptAnalyzer: N findings reported, not enforced` and a table by rule.
Fatal: `ParseError`, anything of severity `Error`, and four named warning rules.
Everything else is counted so the number stays visible.

CI (`.github/workflows/ci.yml`) runs this same suite on `windows-latest`, and in
a second job compiles the extension. That is all it can prove: a hosted runner
has no Zellij, no PowerToys, no Command Palette and no attached terminal, so
steps 5 to 7 below are yours to do on a real desktop.

## 3. Confirm no personal identifiers

`tests/Placeholders.Tests.ps1` runs as part of step 2 and enforces the
anonymisation: no personal name in any tracked file, no unreplaced angle-bracket
draft placeholder, the owner placeholder only in the three sanctioned files, and
every relative markdown link resolving to a file that exists.

The one thing to know about it: it enumerates with `git ls-files`, so an
untracked file is invisible to it. Commit first, then run - otherwise the file
that fails the rule is exactly the one the check cannot see, and the next
`git add` publishes it. A name or a broken link that reaches a public repo
cannot be recalled from anyone's clone.

## 4. Bump the version

In `module/ZellijTerminal/ZellijTerminal.psd1`: `ModuleVersion`, and a new
leading clause on `PrivateData.PSData.ReleaseNotes`, which is one string with
each version in front of the last.

Skip it and the junction bites: an installed copy *is* the clone, so anyone who
pulls gets the new behaviour under the old version number, and there is no way
to tell which version's failure they are describing.

## 5. Verify install.ps1 on a machine without Zellij

The `[0/3] Zellij` block only executes when `zellij` is missing or older than
0.44, the first native Windows release. On a developer box it never runs, which
makes it the path that is never exercised: `Get-ZellijVersion`, the
`ShouldContinue` prompt, the winget install, `Sync-PathFromRegistry` (winget
updates the stored PATH, not the one this process started with) and the re-check
afterwards. Taking `zellij` out of `$env:PATH` reaches the same branch, but only
a machine that genuinely lacks it exercises winget and the PATH refresh.

Skip it and the first thing a new user meets is the only branch nobody has run.

## 6. Verify the 5.1 gate under a real Windows PowerShell

```powershell
powershell.exe -NoProfile -File .\install.ps1
```

Expect the "needs PowerShell 7 or later" message and a return, with nothing from
the steps below it. Then the `iex` path the README actually advertises:

```powershell
powershell.exe -NoProfile -Command "Get-Content .\bootstrap.ps1 -Raw | Invoke-Expression"
```

`#Requires` is only honoured when a script is invoked, so `bootstrap.ps1` checks
`$PSVersionTable` at runtime instead.

`Compat.Tests.ps1` already asks a real 5.1 to *parse* `install.ps1`,
`bootstrap.ps1`, `scripts\*.ps1` and `hooks\*.ps1` - and skips that Describe
where `powershell.exe` does not exist. Parsing is not running. Skip this and a
7-only construct turns the friendly gate into a ParserError, because the parse
happens before the first line runs; that is the failure the whole 5.1 contract
exists for.

## 7. Build the extension

```powershell
cd cmdpal
.\pack.ps1
```

Publish, `makeappx`, `signtool`, `Add-AppxPackage`. Needs the .NET 10 SDK and
the Windows SDK the csproj targets (10.0.26100.0).

CI builds and deliberately stops there. Signing needs a certificate whose
subject equals the manifest's `Publisher` exactly (`CN=ZellijTerminal`); the
private key is not going into a public repo, and a fresh self-signed one per run
would sign a package nobody's machine trusts. `Add-AppxPackage` then needs that
certificate in `LocalMachine\TrustedPeople`, which is elevation, plus a user
session with developer mode on - and the runner has no Command Palette to
install into and is destroyed at the end of the job. So packing and signing stay
local, run from the machine that will use the extension.

Nothing packaged is committed: `cmdpal/out/` and `cmdpal/staging/` are ignored.
Users build their own, as the README tells them to. Skip this step and that
instruction is untested; the rest of the rig is unaffected, because the
installer never touches the extension.

## 8. Mark the version

```powershell
git tag -a v0.5.0 -m 'v0.5.0'
```

Match the tag to `ModuleVersion`, and put it on the commit `main` points at. The
tag is a marker, not the artefact: `bootstrap.ps1` does `git clone --depth 1`
with no branch, and the README one-liner fetches
`raw.githubusercontent.com/<owner>/zellij-terminal/main/`, so what a new user
gets is the tip of the default branch. A tag on anything else installs to
nobody.

Pushing is a fork's business - this repository's `main` is regenerated by its
maintainer, so there is nothing here for a pull to fast-forward. In a fork, push
the branch and the tag as two commands:

```powershell
git push origin main
git push origin v0.5.0
```

Two commands rather than `--follow-tags`, on purpose. `--follow-tags` pushes
every annotated tag reachable from the ref you are pushing, which is a set
nobody has looked at; and where the tag sits on a branch you are not pushing, it
quietly pushes none and still exits 0. Naming the tag means the command's output
tells you which tag went.

There is no gallery publish and no release automation in this repository: no
`Publish-Module`, no release job.

## What is deliberately not shipped

**No telemetry.** Nothing in the module, the scripts or the hook makes a network
call. The only outbound traffic any of this causes is git and winget in the
installer, both run in front of you, and the `zjstatus.wasm` download you do by
hand.

**Nothing written outside your user profile and the clone.** `install.ps1` says
so in its header, and it holds for every path it touches:

- the module junction on your user module path - a junction, not a symlink, so
  no elevation and no developer mode
- `%APPDATA%\Zellij\config\config.kdl` and `layouts\claude.kdl`, each backed up
  first if it already exists
- `.claude\settings.json` inside the clone
- `%LOCALAPPDATA%\ZellijTerminal\devices\<HOST>.json`, which only this machine
  writes — outside the clone on purpose, so a `git clean`, a re-clone, or a
  rebuilt worktree cannot take the registry with it
- a Windows Terminal profile as a **fragment**, at `%LOCALAPPDATA%\Microsoft\
  Windows Terminal\Fragments\ZellijTerminal\zellij-terminal.json`, plus the icon
  beside it at `%LOCALAPPDATA%\ZellijTerminal\zellij-logo.png`. A fragment
  rather than an edit to `settings.json`, because that file is JSONC and the
  user's: a read-modify-write through `ConvertTo-Json` would strip every comment
  in it, and uninstalling is then deleting one file. The icon is **extracted
  from the installed `zellij.exe`**, not committed — Zellij is a prerequisite so
  the asset is always there, and shipping a copy would redistribute someone
  else's mark from a public repo. Both are removed on uninstall.

Live state is one small file per session under
`%LOCALAPPDATA%\ZellijTerminal\live\`, written by the hook and never in git;
hook failures go to `%TEMP%\claude-zellij-hook.log`. `zt pad install` writes
PowerToys' own Keyboard Manager config under `%LOCALAPPDATA%`.

**Two exceptions, both opt-in and both announced.**

- *Elevation*: trusting the Command Palette extension's self-signed certificate.
  `Import-Certificate -CertStoreLocation Cert:\LocalMachine\TrustedPeople` is
  machine-wide. `pack.ps1` prints the exact command rather than attempting it,
  and the install fails with `0x800B0109` until you run it. Nothing else in the
  repo asks for administrator.
- *Writing outside the clone*: `install.ps1 -Global` writes
  `%USERPROFILE%\.claude\settings.json`, so the hook fires for every project
  rather than this repo only. It merges rather than replaces - that file holds
  your permissions and plugins - swapping the `hooks` key wholesale, backing the
  file up first, and refusing outright if what is there is not valid JSON.

## Testing the uninstaller

A release is not testable if it cannot be removed. Before tagging:

```powershell
zt uninstall -WhatIf     # enumerates every step, changes nothing
zt uninstall -Force
```

Then check the things it promises to preserve: your workspace registrations
survive without `-Purge`, the global Claude Code settings keep every key except
`hooks`, and the Zellij config it restores is the one you had before installing -
not a copy of the deployed one. `tests/Uninstall.Tests.ps1` asserts the source
guards; only a real run proves the outcome.