# zt — run several Claude Code sessions from one terminal

Windows. Native, not WSL.

If you run more than one Claude Code session at a time, you spend the day
hunting: which one finished, which is asking permission, which has been sitting
idle for an hour. `zt` puts them all in one Zellij session, one tab per project,
and tells you which one wants you.

```powershell
zt                    # what you have, and what is running
zt start api          # open its tab and run Claude in it
zt go                 # jump to whoever is waiting
zac                   # attach, or focus the window already attached
```

Sessions register themselves. Start Claude Code in a folder and it appears in
the list — a hook writes a small record, and `zt` picks it up.

## What it gives you

**A list that knows what is happening.**

```
  ID                   STATE        AGE       KIND     PATH
  ----------------------------------------------------------------
  api                  WAITING      6m        claude   C:\code\api
                         ^ Notification
  web                  running      2h        claude   C:\code\web
  notes                stopped                claude   C:\code\notes
```

**Stop, restart, park.** `zt stop api` sends Ctrl+C and leaves the tab as a
shell. `zt restart api` **resumes the same Claude conversation** — the hook
recorded its session id. `zt park` stops everything and remembers it; `zt
restore` brings it back, resuming each conversation.

**One project list across several machines.** Definitions are `{root, rel}` — a
named root plus a relative path — and each machine says where its roots are. One
shared list in `config/workspaces.json`, different drive letters, and a project
the current machine cannot reach simply is not offered. What *this* machine has
registered is kept outside the clone, in
`%LOCALAPPDATA%\ZellijTerminal\devices\<HOST>.json`, so `git clean`, a re-clone
or a moved folder cannot take your project list with them. `zt config` opens it;
`zt config -PathOnly` says where it is.

**A Command Palette extension**, with the workspace count in the dock so it is
visible without opening anything, and every verb behind a shortcut.

**Optionally, a macro pad.** A four-key USB pad answers prompts and jumps
between projects without the terminal being focused, or even visible. That is
the origin of this project; the rest grew around it.

## Install

Requires **Windows**, **PowerShell 7**, and **Zellij 0.44+** (the first release
that runs natively on Windows).

```powershell
irm https://raw.githubusercontent.com/ztpwsh/zellij-terminal/main/bootstrap.ps1 | iex
```

Or clone it yourself, which is the same thing without the middleman:

```powershell
git clone https://github.com/ztpwsh/zellij-terminal
cd zellij-terminal
.\install.ps1
```

Either way: the module is junctioned onto your PowerShell module path, Zellij's
config and the `claude` layout are written with your paths filled in, and the
Claude Code hook is registered for this repo. Nothing needs elevation, and
nothing is written outside your user profile and the clone.

It also contributes a Windows Terminal profile so the session tab carries
Zellij's icon rather than the generic console one. That is a *fragment* file, so
your own `settings.json` is never edited — and the icon is extracted from the
`zellij.exe` you already have rather than shipped in this repo. **Terminal reads
fragments at startup**, so restart it once to see the icon.

**Keep the clone.** The module is junctioned to it, not copied — so editing the
repo changes the installed commands, and deleting it breaks them.

To remove it again:

```powershell
zt uninstall -WhatIf   # every step it would take, changing nothing
zt uninstall           # your workspace registrations are kept
zt uninstall -Purge    # those as well
```

It restores the Zellij config you had before installing, takes only its own key
out of your global Claude Code settings rather than the file, and leaves Zellij,
PowerToys and the .NET SDK alone — it did not install them. It says all of that
as it goes.

To back it up, or set the same thing up somewhere else:

```powershell
zt export              # registrations, roots, and this rig's Command Palette entries
zt import <file>       # merge it in on the other machine; -WhatIf first
```

Workspaces defined against a root travel between machines with different drive
layouts; the export tells you how many are pinned to an absolute path and
therefore will not, and the import names each one it cannot reach here along
with the command that fixes it. `zt uninstall -Purge` exports first, so the one
irreplaceable thing is never destroyed without a copy.

Then let it walk you through the rest:

```powershell
zt setup              # guided: explains each layer, offers to do it
```

`zt setup` goes through all six layers in dependency order — Zellij itself, the
config, the Claude Code hook, the session, and the two optional extras. It
explains what each one is for *before* offering to set it up, marks the optional
ones as optional, and changes nothing without asking. It offers to fetch Zellij
with winget if it is missing. Run it unattended and it reports rather than
prompting, so it doubles as a status page.

If you would rather do it by hand:

```powershell
zac                   # start the session
zt add .              # register a project, from inside it
zt check              # verify every layer
```

### Setting up on another machine

There is a Claude Code skill in this repo for exactly that. Open the clone in
Claude Code and ask it to set zt up — it walks the prerequisites, runs the
install, verifies each layer, and knows the failure modes that are silent:

```
/zt-setup            or just: "set zt up on this machine"
```

It also diagnoses an install that has stopped working, which is where it earns
its keep — most failures here look identical from the outside.

### Optional pieces

Neither is required, and `zt setup` explains both in place. To read up first:

```powershell
zt pad explain        # what the four keys are for, and whether you want them
zt palette            # what the Command Palette extension adds
```

**Macro pad** — any device that can emit `Ctrl+Shift+F13`–`F16`: a macro pad, a
keyboard layer, a foot pedal. It answers the session you are looking at without
reaching for the keyboard, and jumps to whichever one is waiting. The chords are
chosen to collide with nothing; `pad/README.md` explains the reasoning before you
change them.

```powershell
zt pad install        # writes four PowerToys Keyboard Manager remaps
```

then **toggle Keyboard Manager off and on** in PowerToys Settings. Its engine
reads that config when it starts, not when the file changes — `zt pad` warns you
when it is stale.

**Command Palette extension** — puts the workspace list in PowerToys Command
Palette, so `Win+Alt+Space` and a few letters gets you to a session. Needs the
.NET 10 SDK and a NuGet source:

```powershell
winget install Microsoft.DotNet.SDK.10
cd cmdpal
.\pack.ps1            # build, sign, install
```

The first build makes a self-signed certificate and prints one elevated command
to trust it; the install fails with `0x800B0109` until you run it. Restart
Command Palette afterwards, or it keeps running the extension it loaded at
startup.

**Status bar** — download `zjstatus.wasm` from
[dj95/zjstatus](https://github.com/dj95/zjstatus/releases) into
`%APPDATA%\Zellij\data\plugins\` for coloured per-project activity.

## The one thing to know

**Almost every failure in this stack is silent and exits 0.**

With nothing attached to the Zellij session, `write`, `go-to-tab-name` and
`close-tab` all do nothing and report success. Keyboard Manager ignores quoted
arguments and reports nothing. A hidden window swallows every error a launched
script prints. None of it appears as an error anywhere.

So when something does nothing, start here:

```powershell
zt check              # all four layers, independently
zt pad probe          # which pad chords actually arrive
```

Both exist because guessing costs hours and these cost seconds.

## Commands

| | |
|---|---|
| `zt setup` | guided setup — start here on a new machine |
| `zt uninstall` | remove everything the installer added; `-WhatIf` first |
| `zt export [path]` · `zt import <file>` | back up your setup, or move it to another machine |
| `zt` · `zt ls` · `zt waiting` | list, filtered |
| `zt add [path]` · `zt rm <id>` | register, unregister |
| `zt add . -Kind pwsh -Command '…'` | a command instead of Claude; omit `-Command` for a bare shell |
| `zt add -FromBookmarks` | import your Windows Terminal profiles as workspaces |
| `zt start` · `stop` · `restart` · `close` | lifecycle; omit the id for a picker |
| `zt go` · `next` · `prev` · `pick` | move between projects |
| `zt park` · `zt restore` | stop everything, bring it back |
| `zt flag <id>` | raise a hand — a build can do this too |
| `zac` · `zt sessions` | attach; the level above tabs |
| `zt check` · `zt validate` · `zt pad` | diagnostics |
| `zt pad explain` · `zt palette` | what the optional pieces are for |
| `zt config` · `zt roots` | the JSON, and what paths mean here |

Every verb is a `Verb-ZellijTerminal` function underneath, so they tab-complete
and take named parameters. `zt help` lists the lot.

## Documentation

| | |
|---|---|
| [User guide](docs/user-guide.html) | what it does and why, in plain language — [rendered](https://htmlpreview.github.io/?https://github.com/ztpwsh/zellij-terminal/blob/main/docs/user-guide.html) |
| [Setup and daily use](docs/05-usage.md) | install steps, then the loop you actually run |
| [Workspaces](docs/06-workspaces.md) | how the registry works, and across machines |
| [Troubleshooting](docs/03-troubleshooting.md) | when something does nothing |
| [Reference](docs/04-reference.md) | every command, and the Zellij CLI |
| [Command Palette extension](cmdpal/README.md) | building and installing it |
| [The pad](pad/README.md) | any device, and why these four chords |
| [The hook](hooks/README.md) | what makes a session raise its hand |
| [Setup skill](.claude/skills/zt-setup/SKILL.md) | the Claude Code skill that installs and diagnoses |

## Licence

MIT.


