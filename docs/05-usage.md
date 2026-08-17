# Using it

Setup once, then the daily loop. If something doesn't work, run
`zt check` (or `.\scripts\Test-Setup.ps1` before you have installed the
module) before changing anything — it isolates which of the four layers is at
fault.

Everything below is verified on this machine: Zellij 0.44.3, Windows 11,
PowerShell 7.6.4 with Windows PowerShell 5.1 for hooks, zjstatus v0.24.0.

---

## Part 1 — Setup

> **The short version:** run `zt setup`. It walks these same layers in
> dependency order, explains each one before offering to do it, offers to fetch
> Zellij with winget if it is missing, and marks the optional pieces as optional.
> Run it with nothing attached and it reports instead of prompting.
>
> The rest of this page is what `zt setup` is doing, for when you want to do it
> by hand or work out why a step did not take.

Six steps. Step 0 is optional but saves typing forever after. Steps 1–3 give you
a working Zellij session with Claude tabs and the waiting-flag machinery.
Steps 4–5 add the status bar and the pad itself.

### 0. Install the commands

```powershell
cd C:\code\zt
.\install.ps1
```

That junctions `module\ZellijTerminal` into your user modules directory, so the
rig's commands work from any directory without a `.\scripts\` prefix:

```powershell
zt                    # what is registered, and what is running
zt add .              # register the folder you are in
zt start api          # open its tab and run it
zt stop api           # Ctrl+C it, keep the shell
zt restart api        # stop, then resume the same Claude session
zt close api          # close the tab, keep the registration
zt go                 # jump to whoever is waiting
zt check              # the layer check
zac                   # attach, or focus the window already attached
zt help               # everything
```

Behind `zt` are `Verb-ZellijTerminal` functions that tab-complete, take named
parameters and support `-WhatIf`. The registry, and how it works across several
machines, is `docs/06-workspaces.md`.

No `$PROFILE` edit and no `Import-Module`: the manifest names its functions and
aliases, so PowerShell autoloads the module the first time you type one.

It is a junction rather than a copy, so editing the repo changes the installed
commands with no reinstall step. It is a junction rather than a symlink because
junctions need no elevation.

**This is convenience, not plumbing.** The macro pad and the Claude Code hook
call the scripts under `scripts\` directly and never touch the module — the pad
because a module import would be paid on every key press, the hook because it
runs under Windows PowerShell 5.1. Skip this step and everything still works;
you just type paths.

### 1. Deploy the Zellij config and layout

Confirm where Zellij actually looks — **note the extra `config` level**, which
is easy to get wrong:

```powershell
zellij setup --check     # prints [CONFIG DIR] and [LAYOUT DIR]
```

```powershell
copy .\zellij\config.kdl "$env:APPDATA\Zellij\config\config.kdl"
mkdir "$env:APPDATA\Zellij\config\layouts" -Force

# The layout is a TEMPLATE - it carries absolute paths, so it is rendered
# rather than copied. There is no claude.kdl in the repo to copy.
$layout = Get-Content .\zellij\layouts\claude.kdl.template -Raw
$layout = $layout.Replace('{{PLUGINS}}', "$env:APPDATA\Zellij\data\plugins".Replace('\', '/'))
$layout = $layout.Replace('{{REPO}}',    $PWD.Path.Replace('\', '/'))
Set-Content "$env:APPDATA\Zellij\config\layouts\claude.kdl" $layout -Encoding UTF8
```

Leave a `{{...}}` unreplaced and nothing errors: the status bar silently never
loads, and the tab opens in the wrong directory.

Edit the layout's tab list to a project you actually have. A tab whose `cwd`
does not exist does **not** error — Zellij falls back silently and you get a tab
in the wrong directory.

### 2. Start the session

```powershell
zac                          # with the module installed
zellij attach --create claude   # the same thing, by hand
```

`zac` is worth using from the start rather than attaching by hand. It asks who
is attached first, so it either opens a window on the session or brings the one
already showing it to the front, instead of stacking up clients you then have to
tell apart. It also names that Windows Terminal window `claude`, which is the
only handle Windows Terminal gives you for finding a window again.

Use exactly that form. `zellij --session claude --layout claude` looks
equivalent and is not: with `--session`, `--layout` means *"add these tabs to
the existing session"*, so on a session that doesn't exist yet it fails with
`Session 'claude' not found` and starts nothing. `default_layout` in the config
plus `attach --create` is the only combination that gives both a name and a
layout.

Ideally add a dedicated Windows Terminal profile running that command, so the
session is one click away. See `zellij/README.md`.

### 3. Register the hook

The hook is what makes a tab raise its hand. Either scope works:

- **Project-scoped** — `<project>\.claude\settings.json`. Affects that project
  only, trivially reversible. This repo ships one.
- **Global** — `%USERPROFILE%\.claude\settings.json`. Every project reports.

Copy the block from `hooks/settings.hooks.json`, pointing `-File` at wherever
you keep `hooks/claude-zj-hook.ps1`. Pointing straight at the repo copy is fine
and means edits take effect immediately.

**Do not register `PreToolUse` or `PostToolUse`.** They fire on every tool call
and each hook is a PowerShell start, measured at ~478 ms — about **956 ms of
added latency per tool call**, or roughly 19 seconds on a twenty-tool turn. The
other seven events fire a handful of times per turn and cost about a second per
turn regardless of workload. All the colours that matter come from those.

Verify without involving Claude:

```powershell
'{"hook_event_name":"Stop","cwd":"C:/code/api"}' |
  powershell.exe -NoProfile -File .\hooks\claude-zj-hook.ps1
dir $env:TEMP\claude-zellij-flags        # expect claude-api.json
```

### 4. Status bar (optional)

Download `zjstatus.wasm` from
<https://github.com/dj95/zjstatus/releases> into
`%APPDATA%\Zellij\data\plugins\`, then keep the `default_tab_template` block in
`claude.kdl`. Delete that block if you don't want a bar — flags and key 3 work
without it.

`pipe_status_rendermode "dynamic"` is the load-bearing line. The default
`static` prints the `#[fg=...]` markup literally instead of colouring it, which
is the failure everyone hits first.

### 5. Wire the pad

```powershell
zt pad install        # writes the four PowerToys remaps
zt pad check          # what is wired, what is missing
```

Pick **one** listener; running both double-fires, and `zt pad` refuses to set up
one while the other is live.

**PowerToys Keyboard Manager** is the default — it's already running, so it
costs no extra process. `zt pad install` writes the four remaps, backing up
`default.json` first and leaving any of your own alone. Table in
`pad/powertoys-setup.md` if you'd rather do it by hand.

**AutoHotkey v2** — `zt pad install -Listener ahk`, optionally `-Startup` so it
returns after a reboot. It works, but it adds a resident process.

Keys 1 and 2 call `zellij.exe` directly rather than PowerShell, saving ~500 ms
per press on the two keys where latency is most obvious; only 3 and 4 need a
script, because choosing which tab to jump to is real logic.

| Key | Chord | Does |
|-----|-------|------|
| 1 | Ctrl+Shift+F13 | Enter — accept the highlighted option |
| 2 | Ctrl+Shift+F14 | Esc — reject |
| 3 | Ctrl+Shift+F15 | jump to whichever session is waiting |
| 4 | Ctrl+Shift+F16 | cycle `claude-*` tabs |

Confirm with `zt check` — it now reports whether the chords are
actually mapped, which a running-but-unconfigured listener otherwise hides.

---

## Moving to another machine, or just backing up

```powershell
zt export                     # zt-export-<device>.json, in the current folder
zt import <file>              # merge it in; -WhatIf first, -Force to overwrite
```

The bundle carries your workspace registrations, your root definitions, and the
Command Palette dock bands, hotkeys and aliases belonging to this rig — only
those, never the rest of the palette's settings.

It deliberately does not carry live state, because which tab is open describes a
moment on one machine. Nor the Keyboard Manager remaps, because those hold
absolute paths to one clone and `zt pad install` rewrites them in a second — the
bundle records *that* the pad was set up so the import can say so.

Workspaces defined as `{root, rel}` travel properly. Ones stored as an absolute
path only land on a machine with the same layout: the export says how many of
those you have while you can still fix it with `zt root`, and the import names
each workspace it cannot reach and the exact command that would fix it.

`zt uninstall -Purge` runs an export first and tells you where it put it.

## Removing it

```powershell
zt uninstall -WhatIf   # every step, changing nothing
zt uninstall           # keeps your workspace registrations
zt uninstall -Purge    # those too
```

Do not do it by hand. The module sits on your module path as a **junction**, so a
recursive delete follows the link and takes `module\ZellijTerminal` out of the
clone with it.

It restores the Zellij config you had before installing, removes only its own
`hooks` key from `%USERPROFILE%\.claude\settings.json` rather than the file, and
leaves Zellij, PowerToys and the .NET SDK alone — it did not install them.

## Part 2 — Daily use

### Adding a project

From inside the project directory:

```powershell
zt add .
```

`zt add` registers the folder; `zt start <id>` is what opens the tab and runs
Claude in it. Registering and starting are separate on purpose — the registry
outlives any particular tab, which is what makes stop, restart and "what do I
have on this machine" mean anything.

Most of the time you will not type `zt add` at all: a Claude session started in
a folder registers itself, and shows up the next time you run `zt`.

The id and the tab name come from the directory, and that matters: the hook
derives the same key from the `cwd` Claude reports, so they agree by
construction. If you already keep project bookmarks with
Windows Terminal profiles that name a starting directory:

```powershell
Register-ZellijTerminal -FromBookmarks -Filter 'web*'
```

### Seeing who needs you

```powershell
zt
```

```
  ID                   STATE        KIND     PATH
  --------------------------------------------------------------------
  zt          WAITING      claude   C:\code\zt
                         ^ Stop
  api          running      claude   C:\code\api
  api                  stopped      claude   C:\code\api
```

With the status bar running you get the same information without asking:
a symbol and colour per project, green for done, red for needs-you, yellow for
working.

### The tab says what it is doing

The tab itself carries the same symbol, appended to its name — `claude-web-api ~`
while that session reads files, `claude-web-api v` when it has finished and is
waiting for you. The hook writes it with `rename-tab -t <id>`, which targets one
tab without moving your focus.

| | |
|---|---|
| `v` | finished its turn — waiting for you |
| `!` | notification — wants your attention |
| `?` | asking permission, or a question |
| `*` | working |
| `>` | running a command |
| `~` | reading |
| `#` | writing or editing |
| `@` | fetching something over the network |
| `&` | running a subagent or a skill |
| `.` | just started |

The colour stays on the right-hand widget: Windows Terminal's status plugin
renders a tab name as plain text, so colour markup in it would print literally.
Glyph on the tab, colour on the bar, both from the same table.

A tab's *identity* is its name without the glyph, which matters if you script
against it: everything in this rig strips the glyph before comparing, and
resolves back to the live name before asking Zellij to go to a tab.

If a session works in a subfolder of its project, it is still labelled by the
project — the hook walks up until it finds the tab that actually exists.

### The loop

Work in one tab, leave the others running. When a session finishes or asks for
permission, its flag appears. Press **key 3** and you land on it — oldest
waiter first, and pressing again walks to the next. Answer with **key 1** or
**key 2** without leaving whatever you were doing; those reach the pane even
when the terminal is unfocused or minimised.

### Removing a project

```powershell
zt stop api                   # leaves the tab as a shell
zt close api                  # closes the tab too
```

This closes the tab and anything running in it. Because `close-tab` acts on the
*focused* tab, removal has to focus the target first — so your view will move.
Two guards make that safe: the name must match `claude-*`, and the tab list is
compared before and after, erroring loudly if anything else disappeared.

---

## When nothing happens

**Check for an attached client first.**

```powershell
zellij --session claude action list-clients
```

An empty table under the header means no terminal is attached. In that state
`write`, `write-chars`, `go-to-tab-name`, `close-tab` and `dump-screen` are all
silent no-ops **that still exit 0**, and injected bytes vanish entirely — so
there is no error anywhere to lead you to it. A minimised or unfocused window is
fine. A closed one is not.

`zac` is the fix and the check in one: it reports which case you were in, then
puts a window on the session either way.

This state is easy to end up in without noticing, because the sessions
themselves are unharmed — `zellij list-sessions` shows the session running and
`zt` lists every workspace, while nothing on screen and no key press does anything.

After that, `zt check`, and fix the **lowest** failing layer
first — a broken layer makes everything above it look broken too.

Common ones, in the order they usually bite:

| Symptom | Cause |
|---|---|
| Pad does nothing, no errors | No listener bindings, or nothing attached to the session |
| Two identical windows, and one will not resize | Two clients on one session — Zellij mirrors, and pins the grid to the smallest |
| `Session 'claude' not found` when starting | Used `--session` with `--layout`; or a KDL parse error being reported as this |
| Tab opens in the wrong directory | Its `cwd` doesn't exist — Zellij falls back silently |
| Key 3 lands on a dead tab | Stale flag from a session killed without `SessionEnd` |
| Status bar shows `#[fg=...]` literally | `rendermode` is `static`, not `dynamic` |
| Claude feels slow | `PreToolUse`/`PostToolUse` registered |

`docs/03-troubleshooting.md` has the longer list.

---

## What this does not do

- **The pad only talks to the focused window.** Anything app-aware needs an
  OS-level listener on the host; a Zellij plugin cannot do it, because plugin
  key events only fire when the plugin's own pane is focused.
- **Stale flags are not aged out.** A session killed without `SessionEnd`
  leaves its flag behind, so key 3 will keep offering a tab that is gone.
- **The session must be running and attached.** This is a viewport-optional
  system, not a headless one.



