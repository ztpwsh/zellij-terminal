# Workspaces — the `zt` registry

A workspace is a directory plus what you run in it. `zt` keeps a list of them,
knows which are running, and starts, stops and restarts them.

It is not Claude-specific. A workspace of kind `claude` runs Claude Code; one of
kind `pwsh` runs whatever command line you give it. Everything below applies
equally to both.

---

## The command surface

Two front doors on purpose.

```powershell
zt                    # list this device's workspaces and their state
zt add .              # register the folder you are standing in
zt start api          # open its tab and run its command
zt stop api           # Ctrl+C what is running, keep the shell
zt restart api        # stop, then resume the same Claude session
zt close api          # close the tab, keep the registration
zt unregister api     # forget it - the folder is untouched. Also: rm, remove, forget
zt go                 # jump to whoever is waiting
zac                   # attach, or focus the window already attached
zt help               # the rest
```

`zt` is what you type. Behind it are `Verb-ZellijTerminal` functions that
tab-complete, take named parameters, support `-WhatIf`, answer to `Get-Help`,
and emit objects:

```powershell
Get-ZellijTerminal | Where-Object State -eq 'stale'
Start-ZellijTerminal api -Resume -WhatIf
```

Workspace ids tab-complete from the registry on every command that takes one.

---

## Three stores, three lifecycles

Conflating these is what makes tools like this rot, so they are separate:

| Store | Where | In git | Written by |
|---|---|---|---|
| Shared definitions | `config/workspaces.json` | yes | you, via `zt publish` |
| Device definitions | `%LOCALAPPDATA%\ZellijTerminal\devices\<HOSTNAME>.json` | no | **only that device** |
| Live state | `%LOCALAPPDATA%\ZellijTerminal\live\` | no | the hook, and `zt start` |

**Only one machine ever writes its own device file.** That single rule is what
makes automatic registration safe across several PCs: two machines cannot
conflict because they never touch the same file. Auto-registration is
device-scoped by construction, not by convention.

**The device file lives outside the clone**, because its scope is the machine
while a clone is one checkout of the code that happens to be sitting there.
State kept in a working tree dies to `git clean -xfd`, to a re-clone, or to a
folder move — and two clones give two registries with nothing saying which one
is being read. `workspaces.json` is the opposite case: committed content that
ships with the checkout, so it stays there.

Set `ZT_CONFIG_HOME` to move both files together:

```powershell
$env:ZT_CONFIG_HOME = 'F:\my-private-clone\config'   # both files, one place
```

That is how several PCs share one registry through git, which is what the
original in-clone layout was for. It stays supported as something you choose —
only ever point it at a **private** repo, since the device file names your
machines and drive layout, and never at a directory something else rebuilds.

Ask rather than assume which file is live:

```powershell
zt config -PathOnly      # this device's registry
zt config                # open it in $env:EDITOR, VS Code, or the .json handler
zt check                 # reports the path it read, and how many workspaces
```

**Live state is a directory of small files, not one document.** Several tabs
write concurrently; a single shared JSON would need locking to survive that. The
waiting flags already work this way and it has never gone wrong.

**The registry is a cache. Live Zellij is the truth.** Every read reconciles
against `query-tab-names` and the flag files, so a terminal closed with the X
button shows as `stale` rather than lying about a session that is gone. `zt
sync` clears those.

---

## Paths across machines

Definitions store `{root, rel}` — a named root plus a relative path — not
absolutes:

```jsonc
// config/workspaces.json — shared
{ "id": "api", "root": "code", "rel": "api", "kind": "claude" }
```

```jsonc
// %LOCALAPPDATA%\ZellijTerminal\devices\DESKTOP.json — this machine only
{ "roots": { "code": "F:\\claude" } }
```

```jsonc
// %LOCALAPPDATA%\ZellijTerminal\devices\LAPTOP.json — the other machine
{ "roots": { "code": "C:\\dev" } }
```

One shared config, two drive letters, no per-machine editing. Define roots with:

```powershell
Set-ZellijTerminalRoot code C:\code
Get-ZellijTerminalRoot
```

A workspace whose root is undefined here is simply **not available** here. That
is the whole of "only show me what this device can attach to" — it falls out of
the schema instead of needing a filter. `zt all` shows them anyway if you want
to see what the other machine has.

A folder outside every root registers with an absolute path and is device-only
by definition. `zt publish` refuses it and tells you which root to define,
because an absolute path means nothing on another PC and failing here is far
cheaper than a config that silently does not work on the laptop.

---

## How registration happens by itself

The Claude Code hook already fires on `SessionStart` with `cwd` and `session_id`
on stdin. It now writes one small live record:

```
%LOCALAPPDATA%\ZellijTerminal\live\<key>.json
```

and deletes it on `SessionEnd`. That is all it does. It deliberately does **not**
call into the module: importing a module costs more than the whole hook, the
module sits on the pwsh 7 module path while the hook runs under 5.1, and this
code is on the latency path of every session.

**`SessionEnd` is not guaranteed to run, so nothing may depend on it.** Claude
Code cancels hooks that have not finished by the time it exits —

```
SessionEnd hook [...] failed: Hook cancelled
```

— for every hook registered, not just this one, and `powershell.exe` alone takes
around 500 ms to start. Losing that race is normal. So the record carries
`CLAUDE_PID`, the pid of the claude process, which Claude Code sets in the
environment of everything it spawns and which therefore costs nothing to read.
A reader can then prove the session is gone rather than trusting a deletion that
may never have happened; `startedAt` doubles as the guard against a pid that has
since been reused by something unrelated.

A record whose process is dead is **kept**, and reads as `stale`. It is not
rubbish — it is the whole input to `zt restore` below. Only `zt sync` removes
one.

The next time you run `zt`, any live record in a folder the registry does not
know about is registered on this device, marked `discovered`. In practice that
is immediate. `zt ls -NoDiscover` opts out.

**The key is a hash of the normalised path**, because a workspace's identity is
its directory — two folders called `api` are two workspaces, and renaming a tab
must not orphan its records. The hook computes it with no config lookup and no
state; `Get-ZtKey` in the module computes the same value the same way. Those two
must not drift.

---

## Duplicates, and the collision that was already there

`zt start` never opens a second tab. If the workspace is running it focuses it;
if the tab exists but nothing is running, the command is typed into that shell.

Registration also catches a collision that predates all of this: tab names were
derived from the leaf folder, so `F:\a\api` and `F:\b\api` both wanted
`claude-api`, and `go-to-tab-name` would then pick one arbitrarily — the pad
would silently answer the wrong session. Registering the second one now warns and
assigns a distinct name, and `-Name` lets you choose your own.

---

## Why Stop types Ctrl+C

There is no way to ask Zellij for the PID running in a pane, and no way to
signal one. What there is, is injection — the mechanism this rig already proved
works unfocused and minimised, at ~60 ms. So `zt stop` focuses the tab
and types Ctrl+C, exactly as you would.

Two things make that safe, both learned the hard way:

- **A client must be attached.** With nothing attached, `write`, `write-chars`
  and `go-to-tab-name` are silent no-ops **that still exit 0**, so a Stop
  against a detached session would report success having done nothing. Every
  command that injects checks first and refuses.
- **Focus is confirmed before typing.** `go-to-tab-name` returns when the
  request is queued, not when the switch has happened, and `write` goes to
  whatever pane is focused when the bytes arrive. Losing that race sends Ctrl+C
  into a *different* tab — very possibly a live Claude session mid-turn. This
  was observed during development: the first Stop reported success and the
  target was still running. `Wait-ZtFocus` now polls `current-tab-info` until
  the right tab is focused, and refuses to type if it never is.

The pane runs `pwsh -NoExit`, so what Stop leaves is a prompt in the right
directory. The workspace is still there, just idle — which is why `zt restart`
can simply type the command back in, and why `zt close` is a separate verb.

`zt restart` on a Claude workspace resumes the previous session by default:
the hook recorded its `session_id`, so you get the same conversation back rather
than a blank one. `-Fresh` opts out.

---

## Shutdown, and getting back

There is no shutdown hook, deliberately. Catching Windows on its way down is the
weakest link available: `SessionEnding` gives you a few seconds, the OS can kill
you anyway, and you would be racing to Ctrl+C several Claude sessions inside that
window — every part of it unreliable at exactly the moment reliability matters.

So the loss is made cheap instead. Two things already in place do the work:
`session_serialization` is on, so an exited Zellij session resurrects with its
tabs, names and directories; and the live records carry each Claude `session_id`,
which is what lets a restart resume the same conversation.

```powershell
zt park       # deliberate: stop everything, remember what was running
zt restore    # bring it back, resuming each conversation
```

`zt restore` takes its list from the parked file if you ran `zt park`, and
otherwise from **live records with nothing running behind them**. That second
source is what makes it a recovery rather than an undo: a live record is written
on `SessionStart` and deleted on `SessionEnd`, so one still sitting there with no
session behind it means that session never exited — the machine went down under
it. Those are exactly the workspaces worth bringing back.

This is why nothing prunes live records automatically, however dead they look.
The pid tells `zt` that a session has ended, and that changes its **state** to
`stale`; it does not license anything to delete the record, because a record with
a dead process is precisely what a crash leaves behind and precisely what restore
reopens. Tidying them away on read would turn shutdown recovery into a silent
no-op, and nothing would report the loss.

Park is therefore optional. It makes the return exact; restore works without it.

## Repairing the config by hand

```powershell
zt config          # open this device's file; -Shared for the shared one
zt validate        # say precisely what is wrong
```

Every command is a read-modify-write of those two files and there is no state
anywhere else, so hand-editing is a supported repair rather than a hack.
`zt validate` catches the handful of things that actually go wrong — invalid
JSON, duplicate ids or keys, an entry with neither a root nor an absolute path,
a `pwsh` workspace with no command, a root pointing at a directory that does not
exist on this device, and two workspaces claiming the same tab name.

## Other machines

Zellij has no remote mode, and its IPC is local and unauthenticated — do not
expose it. The safe way to reach a session on another PC is ordinary SSH over a
private overlay:

```powershell
ssh desktop -t "zellij attach claude"
```

with Tailscale (or WireGuard) providing the network, so nothing is published to
the internet and access is scoped per device. Claude Code itself stays where it
is; you are borrowing a terminal, not duplicating a session.

The schema already has the hook for this: a device record can carry
`remote: { host }`, and `Connect-ZellijTerminal -Device <name>` would shell out
to `ssh`. Designed in, not built — there is no real need yet.

---

## Taking it with you

`zt export` writes one file holding the registrations, the root definitions, and
the Command Palette dock bands, hotkeys and aliases that belong to this rig.
`zt import` merges one back, adding what is missing and leaving what is already
there — so importing the same bundle twice does nothing the second time.

```powershell
zt export                     # zt-export-<device>.json
zt import <file> -WhatIf      # see it before it lands
zt import <file>              # -Force to overwrite existing entries
```

This is where the `{root, rel}` split earns its keep. A workspace stored that
way resolves against whatever the other machine calls that root; one stored as an
absolute path cannot. Rather than let you find that out afterwards:

- **export** counts the absolute-path entries and says so while you are still on
  the machine where `zt root` can fix them;
- **import** names every workspace it cannot reach here, and prints the exact
  `zt root <name> <path>` that would resolve each.

Two things stay behind on purpose. Live state, because which tab is open
describes a moment on one machine and importing it would invent workspaces that
are running when nothing is. And the Keyboard Manager remaps, because they store
absolute paths into one clone — the bundle records only *that* the pad was set
up, so the import can tell you to run `zt pad install`.

`zt uninstall -Purge` exports before it deletes. The registrations are the only
thing here that cannot be regenerated, and `-Purge` is one word away from
`-WhatIf`.

## What is deliberately not in git

`%LOCALAPPDATA%\ZellijTerminal\live\` — session ids, start times, which tab.
It is device state, it is disposable, and committing it would mean every session
start dirtying the working tree. `config/` is the part worth keeping, and it
changes only when you add or publish a workspace.

