# Decisions

Every entry here is a choice this repo actually made, with the alternative it
turned down and the reason. Several of the rejected ones look better than what
was kept until you try them, which is the whole point of writing them down.

The numbers are stable and are cited from the code: `zellij/README.md` points at
D4, the layout template at D5, and `04-reference.md` at D6. Renumbering breaks
those references, so new decisions go on the end.

---

## Zellij itself

### D1 — One session, one tab per project

Everything lives in a single Zellij session, `claude`, with one tab per
workspace. That is why `query-tab-names` is enough to answer "what is open",
why the cycle keys can walk projects with one call, and why the hook can pipe a
single status line listing every project at once — the state map is keyed by
Zellij session name.

**Rejected:** a session per project. Sessions are separate servers with their
own tabs and clients, so every cross-project question would have to be asked
once per server. The session level is also where strays accumulate quietly —
`session_serialization` keeps exited ones and a mistyped command creates a whole
new server named after a random animal — which is why `zt sessions` exists as a
tidying tool rather than as the level you work at.

### D2 — `default_layout` plus `attach --create`, never `--session` with `--layout`

The layout is named in `config.kdl` as `default_layout "claude"`, and everything
that opens the session runs `zellij attach --create claude`.

**Rejected:** `zellij --session claude --layout claude`, which looks like the
obvious spelling and is not. Per `zellij --help`, `--layout` combined with
`--session` means "add these tabs to the **existing** session", so against a
session that does not exist yet it fails with `Session 'claude' not found` and
starts nothing. Confirmed on 0.44.3. Worse, a KDL parse error in the layout is
swallowed and reported as the same "Session not found", so the one form that
fails is also the form that misreports why. `default_layout` plus `attach
--create` is the only combination that gives a named session *and* a layout. To
parse-check a layout on its own: `zellij -l <name>`, no `-s`, exit 0 means it
parsed.

### D3 — Drive Zellij over its CLI from outside

Every action in the rig is `zellij --session <name> action <...>` run from an
ordinary process outside the session.

**Rejected:** a Zellij plugin. A plugin only receives key events when its own
pane is focused, so a macro pad could never reach it — which defeats the premise
that you answer a session without looking at it. Also rejected: driving the
terminal window instead of Zellij. `pad/macropad.ahk` is kept as the record of
that attempt: it activates the terminal, sends the key and restores your
previous window, roughly 100 ms with a visible flash, and the flash is
unavoidable because `ControlSend` posts messages to a window handle while
Windows Terminal renders through DirectX and reads the focused-window keyboard
path.

### D4 — One Windows Terminal profile, not one per project

A single profile whose command line is `zellij.exe attach --create claude`. It
reuses the session when it is running and creates it otherwise, so closing the
tab loses nothing and reopening drops you back in.

**Rejected:** a profile per project. Project tabs are created at runtime (D10),
so there is nothing to enumerate when the profile list is written; and any
second profile would run the same `attach --create` and simply attach another
**client** to the same session, showing the same tabs — and pinning the grid to
the smallest of them, so neither window resizes and the text stops reflowing.
That is how you end up with several windows you then have to tell apart, which
is exactly what `zac` exists to prevent — it asks who is attached first and
raises the existing window rather than stacking up another client.

### D5 — `default_mode "locked"`

The session starts locked, so Zellij claims no keys and passes everything
through to whatever is running in the pane. `Ctrl+g` unlocks it if you want
Zellij's own keybindings interactively. The status bar styles `LOCKED` as calm
grey rather than as a warning, because it is the normal state here.

**Rejected:** Zellij's default mode with its usual keybindings, unpicking the
clashes with Claude Code one at a time. Nothing is lost by locking: tab
navigation is driven over the CLI by the pad and by `zt`, so Zellij's own
keybindings are never needed in normal use.

### D6 — Focus the target and prove it before acting

`close-tab`, `write` and `write-chars` all act on the **focused** tab or pane,
and there is no reliable pane-to-tab lookup on the CLI. So anything that acts on
a named tab focuses it first — and then confirms the focus actually moved.

**Revised 0.7.2: `rename-tab` is no longer in that list.** It takes `-t <id>`,
which targets a tab without moving focus — retested on 0.44.3 after this
decision had recorded the opposite for months. That is what allows the hook to
put an activity glyph on the tab it belongs to while you carry on working in
another. The bare form is unchanged and still focus-only. `close-tab-by-id` and
`go-to-tab-by-id` exist as well and would retire the focus-then-act dance
entirely; that work has not been done. `go-to-tab-name` returns when the request is queued, not when the switch
has happened, and injected bytes go to whatever pane is focused when they
arrive. Losing that race sends Ctrl+C into a different tab, very possibly a live
session mid-turn; it was observed during development, with the first Stop
reporting success while the target carried on running. `Wait-ZtFocus` polls
`current-tab-info` until the right tab answers, matching `name: <tab>` followed
by `id:` so that `claude1` cannot match `claude10`. Tab removal additionally
compares the tab list before and after and errors loudly if anything else
disappeared.

**Rejected:** treating those commands as though they addressed a tab by name,
and — for the hook — renaming tabs to show state. A hook fires in a background
tab, so a rename would retitle whatever you happened to be looking at. State
goes to a piped status line instead, which is also how the upstream project
avoids the same trap.

### D7 — Stop injects Ctrl+C rather than signalling a process

There is no way to ask Zellij for the PID running in a pane and no way to signal
one. What there is, is injection, which this rig had already proved works with
the terminal unfocused or minimised, at about 60 ms. So `zt stop` focuses
the tab and types Ctrl+C, exactly as you would — twice, with a gap, because
Claude Code treats a single Ctrl+C as "clear the input line" and only exits on
the second. The pane runs `pwsh -NoExit`, so what is left behind is a prompt in
the right directory, which is what makes `zt restart` a matter of typing the
command back in and `zt close` a separate verb.

**Rejected:** killing the process, and closing the tab as a way of stopping
work. Both throw away the shell and the directory along with the session.

There is a hard precondition either way: **a client must be attached**. With
nothing attached, `write`, `write-chars`, `go-to-tab-name` and `close-tab` are
silent no-ops **that still exit 0**, so a Stop against a detached
session would report a success that never happened. Every command that injects
checks `list-clients` first and refuses.

---

## Naming and addressing

### D8 — The tab-name prefix is the addressing scheme

Tabs are named `<prefix><leaf>` — `claude-api` for `C:\code\api`. Three separate
components derive that name the same way and never coordinate: the hook, from
the `cwd` Claude Code sends on stdin; `zj-claude-tab.ps1`, which filters the tab
list on the prefix; and `zj-claude-project.ps1`, which creates the tabs.
Because all three derive it identically, adding a project needs no configuration
anywhere. The prefix is also the safety guard: `-Remove` refuses any name
outside the managed namespace, so a stray argument cannot close a tab you did
not mean.

**Rejected:** stamping tabs with metadata and looking projects up by it, the way
a bookmarks module can filter Windows Terminal profiles by a GUID prefix.
Zellij tabs carry no metadata to stamp. A name prefix is the weaker equivalent,
which is why removal has the before/after check as a second line of defence.

The known cost is collisions: `F:\a\api` and `F:\b\api` both want `claude-api`,
and `go-to-tab-name` would then pick one arbitrarily and the pad would answer the
wrong session. Registration now warns and assigns a distinct name, and `-Name`
lets you choose one.

### D9 — The Claude session display name drops the prefix the tab keeps

The tab stays `claude-web-api`; `claude --name` gets `web-api`. The
prefix is Zellij bookkeeping — it is how the cycle keys know which tabs are
projects and how the hook recognises its own. Claude Code has no use for it, and
the display name is what shows in the prompt box, the `/resume` picker, and on
mobile and desktop, where "claude-web-api" reads as though the tool were
part of the project's name.

**Rejected:** passing the tab name through unchanged, and dropping the prefix
from the tab names as well. They are free to differ because nothing matches on
`--name`: the hook derives the tab from `cwd`, and on native Windows `--name` is
not an address at all — cross-session messaging is not offered here, confirmed
by `CLAUDE_CODE_MESSAGING_SOCKET` being unset on 2.1.232. An explicit name that
does not use the prefix passes through untouched, and so does a collision
suffix: `claude-api-3f2a` becomes `api-3f2a`, which is still what tells it apart
from the other `api`.

### D10 — One startup tab, not a tab per project

`claude.kdl` opens exactly one tab, `home`, with `cwd` at the repo, running `zt`.
A Zellij session must have at least one tab, so "start with none" means "start
with one that is not a project". It runs `zt` because on a cold start the only
question you have is what have I got: on a fresh install that prints the
"nothing registered yet" hint, and afterwards the workspace table with states.
It is deliberately **not** named `claude-*`, so the cycle keys walk past it.

**Rejected:** hardcoding project tabs in the layout. That is what the first
install did, and it produced duplicates immediately — the layout opened a tab on
the repo, `zt add .` registered the same folder, and there were two tabs on one
directory. Also rejected: a static welcome message in that tab, which would have
to be kept true by hand. Two things assumed a `claude-*` tab always existed and
were adjusted to tolerate none: `Test-Setup.ps1`, where it was a FAIL, and
`zj-claude-tab.ps1`, where it was a `Write-Error`.

### D11 — Every pane runs a prelude, and `zac` scrubs the environment first

Each pane the rig opens runs `pwsh -NoExit -Command` with a short prelude that
sets `TERM` and `COLORTERM` and removes `NO_COLOR` and
`CLAUDE_CODE_CHILD_SESSION`. Three separate failures motivate it. `TERM` and
`COLORTERM` are both empty in a Zellij pane on Windows, verified with a probe
pane, so TUIs decide there is no colour. Panes inherit the environment of the
Zellij **server**, not of whatever asked for the tab, so a server ever started
from inside a Claude Code session hands every pane
`CLAUDE_CODE_CHILD_SESSION` and Claude reports "Transcript saving is off".
`NO_COLOR` arrives the same way and is worse: Claude Code sets it for the
commands it runs, and it is honoured before `TERM` and `COLORTERM` are even
consulted, so the first two assignments become pointless and the whole session
renders black and white — which reads convincingly as "this is cmd, not pwsh".

**Rejected:** fixing it in one place only. `Connect-ZellijTerminal` clears both
variables around the `attach --create` that starts the server, because that is
the source; the prelude stays as the belt to those braces, since the server may
have been started by hand. Neither alone is enough — a tab opened with Zellij's
own keybinding uses `new_tab_template`, a bare pane with no prelude, and would
inherit the server copy while every other tab looked fine.

---

## Storage

### D12 — Definitions in git, live state out of it

`config/workspaces.json` is tracked. The device registry is not: it moved to
`%LOCALAPPDATA%\ZellijTerminal\devices\<HOST>.json`, because state kept in a
working tree dies to `git clean -xfd`, to a re-clone, or to the directory being
rebuilt under it. Live records — session ids, start times, which tab — go to
`%LOCALAPPDATA%\ZellijTerminal\live\` and are never committed.

`ZT_CONFIG_HOME` puts both config files wherever you point it, which is how
several PCs share one registry through a **private** repo — the use the
original in-clone layout was built for, now chosen rather than assumed.

**Rejected:** keeping the running state with the definitions. It is device state
and it is disposable, and committing it would mean every session start dirties
the working tree. The `config/` half changes only when you add or publish a
workspace.

### D13 — One config file per device, written only by that device

Automatic registration writes to this device's registry,
`%LOCALAPPDATA%\ZellijTerminal\devices\<HOSTNAME>.json`, and never to the
shared list. `zt publish` is the separate, deliberate step that promotes an
entry.

**Rejected:** one shared file that every machine appends to. The hook effectively
registers a workspace on every session start, so a shared file would be rewritten
by several machines constantly, and the merge conflicts would arrive in the file
you least want to hand-resolve. Two machines cannot conflict when they never
touch the same file: auto-registration is device-scoped by construction rather
than by convention.

### D14 — Paths as `{root, rel}`, not absolutes

A definition names a root and a relative path; each device maps root names to
its own drive letters. One shared list, `F:\claude` on one machine and `C:\dev`
on another, no per-machine editing.

**Rejected:** absolute paths in the shared config. They mean nothing on another
PC. The schema also earns something for free: a workspace whose root is
undefined here is simply not available here, which is the whole of "only show me
what this device can attach to" without needing a filter. Absolutes are still
allowed for one-offs and are device-only by definition — `zt publish` refuses
them and says which root to define, because failing there is far cheaper than a
config that silently does not work on the laptop.

### D15 — The registry is a cache; live Zellij is the truth

Every read reconciles the two config files against `query-tab-names` and the
waiting flags, and the state comes out of that comparison: `running`,
`tab-only`, `stopped`, `stale`, `unavailable`. A terminal killed with the X
button leaves records behind, so it reports `stale` rather than lying, and `zt
sync` clears those.

**Rejected:** trusting the registry, and the mirror-image alternative of
trusting only Zellij. Reconciliation also has to run the other way: tabs that
exist but are in no registry are listed as `unregistered`, because without that
`zt` shows one workspace while the tab bar shows four and nothing explains the
gap. Those have no path — Zellij will not report a tab's directory — so they can
be stopped and closed but not started until they are registered against a
folder.

### D16 — A workspace's identity is a hash of its directory

The key is the first four bytes of a SHA1 over the lower-cased, separator-
normalised path.

**Rejected:** keying on the name or the tab. Renaming a tab must not orphan a
workspace's records, and two folders called `api` are two workspaces. The hash
matters for one specific reason: the hook has to compute the same key with no
config lookup and no state, on every session start, under Windows PowerShell
5.1. `Get-ZtKey` in the module and `Get-ZtKeyForPath` in the hook compute it the
same way, and must not drift.

### D17 — The hook writes a file; it never calls the module

On `SessionStart` the hook writes one small live record and deletes it on
`SessionEnd`. `zt` turns unknown records into registrations the next time it
runs, which in practice is immediately.

**Rejected:** having the hook call into `ZellijTerminal`. Importing a module
costs more than the entire hook, the module sits on the pwsh 7 module path while
the hook runs under 5.1, and this code is on the latency path of every session.
The hook writes; `zt` thinks.

### D18 — Live state is a directory of small files, not one document

One JSON file per live session, one per waiting flag.

**Rejected:** a single shared state document. Several tabs write concurrently
and one document would need locking to survive it. The waiting flags already
worked this way and never went wrong. Where a shared document is genuinely
needed — the status-bar state map, which has to list every project on one line —
the hook takes a crude file lock, which is the cost being avoided everywhere
else.

### D19 — No shutdown hook; make the loss cheap instead

`zt park` stops everything and remembers it, `zt restore` brings it back and
resumes each conversation, and `session_serialization` is on so an exited Zellij
session resurrects with its tabs, names and directories.

**Rejected:** catching Windows on its way down. `SessionEnding` gives you a few
seconds, the OS can kill you anyway, and you would be racing to Ctrl+C several
sessions inside that window — every part of it unreliable at exactly the moment
reliability matters. Park is therefore optional: it makes the return exact, and
restore works without it by taking live records with nothing running behind them,
which is the signature of a machine that went down under a session rather than a
session that exited.

---

## Installation and the pad

### D20 — The pad calls the scripts, not the module, and keys 1 and 2 skip PowerShell

`scripts\` holds the one implementation of tab creation, removal and switching,
and the module wraps it. Keys 1 and 2 skip PowerShell altogether and call
`zellij.exe` directly, about 60 ms instead of a roughly 500 ms PowerShell
start, both measured, to forward two bytes. Only keys 3 and 4 need a
script, because choosing which tab to jump to is real logic.

**Rejected:** routing everything through the module for consistency. A key press
would pay for a module import each time. Two related details had to be learned
the hard way: Keyboard Manager launches through `run_non_elevated`, whose
environment does not necessarily have `zellij` on PATH, so the pad bindings pass
`-ZellijExe` explicitly; and its `runProgramArgs` does not appear to honour
embedded double quotes, so paths are passed unquoted (falling back to the 8.3
short path where the repo path contains spaces).

### D21 — `Ctrl+Shift+F13`–`F16`, and never `Ctrl+Alt`

`F13`–`F16` are real, sendable key codes that almost nothing binds, because
almost no keyboard has the keys, and `Ctrl+Shift` makes an accidental match
unlikelier still. They also do precisely nothing when no listener is running.

**Rejected:** media or browser keys, which would still do their real jobs, so a
half-configured pad would skip tracks instead of failing quietly. And `Ctrl+Alt`
in any form: on UK and most European layouts `Ctrl+Alt` *is* AltGr, so such a
hotkey fires while typing ordinary characters. The Command Palette shortcuts
avoid `Ctrl+Alt` for the same reason.

### D22 — PowerToys Keyboard Manager by default, AutoHotkey by request

`zt pad install` writes four Keyboard Manager remaps; `-Listener ahk` uses the
AutoHotkey v2 script instead.

**Rejected:** picking one and only one, and picking AutoHotkey as the default.
Most Windows machines already run PowerToys, so Keyboard Manager costs no extra
process where AutoHotkey adds a permanent one — that is the whole of the reason,
not a judgement about the tools. Running both double-fires every key, which
reads as the pad stuttering rather than as a configuration mistake, so `zt pad`
refuses to set up one while the other is live. The remap schema was read out of
the shipped PowerToys binaries rather than guessed, because unknown fields are
ignored silently and a guessed schema would look exactly like a dead pad.

### D23 — The module is junctioned, not copied

`install.ps1` junctions `module\ZellijTerminal` onto the user module path.

**Rejected:** copying it there. A junction means editing the repo changes the
installed commands with no reinstall step. A junction rather than a symlink
because junctions need no elevation — nothing in the install does. The cost is
stated plainly in the README: keep the clone, because deleting it breaks the
commands. It also forces one subtlety, since Windows resolves paths by string:
`$PSScriptRoot` inside the junction is the junction's own path, so `Get-ZtRoot`
follows the reparse point before walking up.

### D24 — Hooks, scripts and installers stay parseable by Windows PowerShell 5.1

No ternary, no `??`, no `&&` or `||` in `scripts\`, `hooks\`, `install.ps1` or
`bootstrap.ps1`. The hook is registered against `powershell.exe`, and the two
installers gate on `$PSVersionTable` — which cannot help, because a parse error
happens before the gate can run.

**Rejected:** registering `pwsh.exe` for the hook so the whole repo could use
PowerShell 7 syntax. The hook also uses the exec form (`args` supplied) rather
than the shell form, which on Windows would default to Git Bash unless `"shell":
"powershell"` is set — and Git Bash brings its own problem, since MSYS rewrites
arguments that look like Unix paths and can silently corrupt the zjstatus pipe
string.

### D25 — The hook always exits 0, and logs its failures to a file

Whatever happens, the hook exits 0 and writes one line per failure to
`%TEMP%\claude-zellij-hook.log`, truncated so it cannot grow without bound, with
successful events logged only under `ZT_HOOK_DEBUG`. `zt check` reports the file.

**Rejected:** letting the hook fail the session, and the original version's empty
`catch` blocks. A hook that fails a session is worse than a hook that fails — but
silence was worse still: this is the least observable thing in the rig, running
detached with output going nowhere, so a malformed payload meant no flag, no
status and no trace, and every downstream symptom pointed at the pad, or Zellij,
or the layout.

### D26 — Seven hook events registered, not nine

The template `install.ps1` writes — `hooks/settings.hooks.template.json` —
registers `SessionStart`, `UserPromptSubmit`, `Notification`,
`PermissionRequest`, `Stop`, `SubagentStop` and `SessionEnd`. One identical block
per event, because the script reads `hook_event_name` from stdin rather than
taking a per-event argument.

**Rejected:** `PreToolUse` and `PostToolUse`, which give per-tool colour detail
and cost too much for it. Each hook invocation is a PowerShell process spawn
measured at about 478 ms under `powershell.exe`, and those two fire on
every tool call — roughly 956 ms per call, or about 19 seconds on a twenty-tool
turn. The seven that are registered fire a handful of times per turn and cost
about a second per turn regardless of workload. `hooks/settings.hooks.json` keeps
the full nine-event form as a reference, with the measurement in its comment.

### D27 — The hook is registered at repo scope by default, and merged at global scope

`install.ps1` writes `<repo>\.claude\settings.json` outright, because the repo
owns that file. With `-Global` it writes `%USERPROFILE%\.claude\settings.json`
instead, and there it **merges**: read the existing document, add the hooks
block, write it back, having taken a timestamped backup first. It refuses to
proceed if the existing file is not valid JSON rather than overwriting it.

**Rejected:** the same write-it-outright treatment at global scope. That file is
where permissions, plugins and the rest of a user's Claude Code settings live,
and replacing it to add a hooks block would be a spectacular way to lose all of
them. Repo scope is the default because it affects one project and is trivially
reversible, and pointing `-File` at the clone means edits to the hook take effect
immediately.

### D28 — A host-side listener, not the actions programmed into the pad

The pad emits four inert chords and something on the PC decides what they mean.

**Rejected:** programming `Enter`, `Esc` and `Ctrl+Tab` straight into the pad's
flash. It is genuinely tempting — zero software, nothing to install, and it
works on any machine you plug the pad into, which is everything this rig is not.
It was turned down because those keys then fire in **every** application: an
`Esc` landing in the wrong window is a real cost, paid at random, and a pad that
is only right when the terminal happens to be focused is the focus problem again
wearing a different hat. Inert chords fail quietly instead — an unconfigured
machine gets four keys that do nothing, which is the correct behaviour for a
device that cannot see what it is talking to.

The trade is accepted rather than mitigated: the meaning lives on this PC, so
the pad is four dead F-keys anywhere else. `zt pad install` is what makes a
machine one where they mean something.

This is the oldest decision here and it predates Zellij entirely — see
`docs/00-background.md`, which is also where the same reasoning ends up ruling
out driving Windows Terminal directly.
