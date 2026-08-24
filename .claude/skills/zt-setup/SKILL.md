---
name: zt-setup
description: Install and verify zt (Zellij + Claude Code workspace rig) on a Windows machine, or diagnose an install that is not working. Use when setting up on a new PC, when zt commands are missing, when the macro pad does nothing, when the Command Palette extension does not appear, or when the user says "set this up on this machine", "install zt", "why isn't the pad working".
---

# Setting zt up on a machine

Walk the user through installing this repo on the machine you are running on,
or diagnose an install that is misbehaving. Work top to bottom — each layer
depends on the one above, and a broken layer makes everything below it look
broken too.

**The single most important thing to know:** almost every failure in this stack
is **silent and exits 0**. When something "does nothing", that is the symptom,
not the absence of one. Never conclude from a command appearing to succeed.

## 0. What is already true

Run these before doing anything, and read the answers rather than assuming:

```powershell
$PSVersionTable.PSVersion          # need 7+; 5.1 cannot autoload the module
zellij --version                   # need 0.44+ — the first native Windows release
Get-Module -ListAvailable ZellijTerminal | Select-Object Version, Path
zellij list-sessions
```

If `zellij` is missing, install it (`winget install zellij` or from
<https://zellij.dev>) and **reopen the shell** so PATH is picked up.

If the module is already listed, this machine is probably installed — jump to
step 4 and verify rather than reinstalling.

## 1. Install

From the repo root:

```powershell
.\install.ps1
```

That junctions the module onto the user module path, writes Zellij's config and
the `claude` layout with this machine's paths filled in, and writes
`.claude\settings.json` so the Claude Code hook points at this clone. Nothing
needs elevation.

Then **open a new shell** — or `Import-Module ZellijTerminal -Force` — because a
module already loaded in the current session stays in memory even though the
files changed. This confuses people constantly; say so rather than letting them
discover it.

Verify:

```powershell
zt                    # should print a table, or "Nothing registered"
```

## 1a. Or just hand it to `zt setup`

The module now ships the same walkthrough this file describes:

```powershell
zt setup
```

It goes through all six layers in dependency order, explains each before
offering to do it, offers to fetch Zellij with winget, and marks the optional
layers as optional. Run non-interactively it reports instead of prompting, so it
is safe for you to run as a status pass.

Prefer it over doing the steps by hand — it cannot drift from the code the way
this file can. Keep reading for the failure modes it does not cover, which is
where you earn your keep.

If `zt` is not recognised in a *new* shell, the junction did not land. Check
`Get-Module -ListAvailable ZellijTerminal` and re-run `.\install.ps1 -Force`.

## 2. Start a session and register something

```powershell
zac                   # opens a Windows Terminal window on the session
zt add . -Start       # from inside a project folder: register it, open its tab
zt start <id>
```

`zac` names the window so it can be found again. If a session exists but nothing
is attached, **every Zellij action silently no-ops while still exiting 0** — so
if later steps do nothing, check this first:

```powershell
zellij --session claude action list-clients   # header only = nothing attached
```

## 3. Roots, if this machine will share a project list

Only needed when several machines share the repo. Definitions are stored as
`{root, rel}` so drive letters can differ:

```powershell
zt roots
zt root code C:\code          # whatever this machine calls it
```

A workspace whose root is undefined here shows as `unavailable` — that is
correct behaviour, not a fault.

## 4. Verify everything

```powershell
zt check              # all four layers, independently
zt validate           # the config JSON
```

Fix the **lowest** failing layer first. `Client attached FAIL` explains most
mysteries on its own.

## 5. Optional: the Command Palette extension

Explain what it adds before asking anyone to install a .NET SDK for it:

```powershell
zt palette            # what it is, and whether it is already installed
```


Needs the .NET **10** SDK — the toolkit references `System.Runtime 10.0.0.0`, so
SDK 9 fails with CS1705 — and a NuGet source, which some machines genuinely do
not have configured:

```powershell
winget install Microsoft.DotNet.SDK.10
dotnet nuget list source                     # if empty:
dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org

cd cmdpal
.\pack.ps1
```

The first run creates a self-signed certificate and prints **one elevated
command** to trust it — the install fails with `0x800B0109` until that is done.
Offer to run it elevated; do not silently skip it.

Then restart Command Palette. Optionally pin the dock band:

```powershell
zt dock
```

## 6. Optional: a macro pad

Any device that can emit `Ctrl+Shift+F13`–`F16` — a macro pad, a keyboard layer,
a foot pedal. **Explain it before offering to install it**; people reasonably
assume a terminal tool has no business wanting hardware, and it is optional:

```powershell
zt pad explain        # what the four keys do, and why you might want them
zt pad install
zt pad
```

**Then tell the user to toggle Keyboard Manager off and on in PowerToys
Settings.** Its engine reads the config *when it starts*, never when the file
changes. Skipping this is the most common reason a freshly installed pad does
nothing — and the most common reason a fixed one keeps misbehaving. `zt pad`
compares the engine start time to the file and reports `STALE`.

If a key does nothing:

```powershell
zt pad probe          # press all four, then -Show, then -Stop
```

That separates three causes which are otherwise indistinguishable because all
three are silent: the chord never arrived, Keyboard Manager never matched it, or
it matched and the launch failed.

## Moving a setup between machines

```powershell
zt export                 # on the old machine
zt import <file>          # on the new one; -WhatIf first
```

Carries registrations, roots and this rig's Command Palette entries. Does not
carry the pad remaps (absolute paths to one clone) or live state. The import
names any workspace it cannot reach here and the `zt root` command that fixes
it — read that list out rather than leaving them to find `unavailable` rows.

## Removing it

There is a real uninstaller; do not do it by hand. The module lives on the
module path as a **junction**, so a recursive delete follows the link and takes
`module\ZellijTerminal` out of the clone with it.

```powershell
zt uninstall -WhatIf     # always show this first
zt uninstall             # keeps workspace registrations
zt uninstall -Purge      # registrations too
zt uninstall -Force      # required when there is nobody to confirm with
zt uninstall -KeepSession   # see below - you almost certainly want this
```

**`zt uninstall` kills the Zellij session first.** Run it from a shell inside
that session and you are killing the terminal you are typing in, which from an
agent's point of view looks like the command hanging and then everything after
it failing. `-KeepSession` leaves the session alone, and is what you want
whenever the uninstall is a step in a reinstall rather than the end of it.

It restores the pre-install Zellij config, removes only its own entries from the
`hooks` key in `%USERPROFILE%\.claude\settings.json` — not the key, not the file
— and does not touch Zellij, PowerToys or the .NET SDK. Hooks registered by
anything else survive; the key goes only when nothing is left in it.

Two things it removes that you have to *restore by hand* on a reinstall, because
they are not part of `install.ps1`:

```powershell
zt pad install           # the 4 Keyboard Manager remaps
.\cmdpal\pack.ps1        # the Command Palette extension
```

And two that need a human afterwards, neither of which any script can do:
**toggle Keyboard Manager off and on** in PowerToys (its engine reads the remap
file at start, so until you do, the pad runs whatever it loaded before), and
**restart Command Palette**. Say both out loud rather than reporting the
reinstall as finished.

Restart **Windows Terminal** too, once: the profile that gives the session tab
Zellij's icon is contributed as a fragment, and fragments are read at startup
only. Until then `zac` deliberately will not ask for it.

## Diagnosing an existing install

| Symptom | Look at |
|---|---|
| `zt` not recognised | new shell? `Get-Module -ListAvailable ZellijTerminal` |
| everything no-ops, no errors | `zellij ... action list-clients` — nothing attached |
| `zt` lists fewer tabs than the tab bar | unregistered tabs: `zt` shows them, `zt add . -Name <tab>` adopts one |
| pad does nothing | `zt pad` for a STALE engine, then `zt pad probe` |
| console flashes on every key press | the Keyboard Manager UI downgraded the remaps — `zt pad install` again |
| extension missing from the palette | `Get-AppxPackage ZellijTerminal.Palette`, then restart the palette |
| workspace shows `unavailable` | no root for it here — `zt roots` |
| workspace shows `stale` | a terminal was closed with the X button — `zt sync` |
| key 3 does nothing, status bar empty | the hook fires only where it is registered. `install.ps1 -Global` registers it for every project; without that it works in this repo alone |
| everything monochrome, prompt unstyled | the zellij server inherited `NO_COLOR=1`, which happens when `zac` is run from inside a Claude Code tool call. Restart the session from a normal shell |
| the hook seems to do nothing | `zt check` now reports a `Hook errors` line, and the hook logs failures to `%TEMP%\claude-zellij-hook.log`. Set `ZT_HOOK_DEBUG=1` for successful events too |
| a tab's glyph is frozen | that session is not firing hooks. Registration is read at session START, so a session that was running when the hook was registered (or unregistered) never sees the change — restart that session rather than debugging the hook |
| two identical windows, and one will not resize | one session, two clients. Zellij mirrors and sizes the grid to the smallest client. `action list-clients`; close the spare. If a cold `zac` made it, Terminal's `firstWindowPreference` is `persistedWindowLayout` — `zt check` reports it |
| the session tab has the generic console icon | Terminal reads profile fragments at startup — restart it once after installing |

## Rules for you, the assistant

- **Never report success from an exit code alone.** Check the observable: a tab
  appeared, a flag file exists, the log recorded a launch.
- **Prefer the tool's own diagnostics** — `zt check`, `zt pad`, `zt pad probe`,
  `zt validate` — over inferring from behaviour. They exist because guessing
  cost hours.
- **Do not kill Command Palette to force a settings read.** It writes settings on
  exit; a hard kill discards them.
- **Do not install a second listener.** PowerToys and AutoHotkey both bound to
  the same chords double-fire every key, which reads as the pad stuttering.
- When something changed but had no effect, ask **what is holding the old copy
  in memory** — an imported module, the Keyboard Manager engine, a running
  palette. That has been the answer more often than anything else.
