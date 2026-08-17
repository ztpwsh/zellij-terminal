# Hooks

## What goes where

Two decisions: where the script lives, and how widely the hook is registered.

**Where the script lives.** Pointing `settings.json` straight at the repo copy
works and means edits take effect immediately - which is what this repo does.
Copy it somewhere stable like `C:\tools\` only if you expect to move or delete
the repo, since the path is baked into `settings.json`.

**How widely it registers.**

- *Project-scoped* - `<project>\.claude\settings.json`. That project only.
  Trivially reversible: delete the file. This repo ships one.
- *Global* - `%USERPROFILE%\.claude\settings.json`. Every project reports in.

Either way, `settings.hooks.json` is a complete `hooks` block - paste it
alongside your existing keys and fix the `-File` path.

**Register seven events, not nine.** See Performance below; it is not a
close call.

## What the hook does

Three jobs from one script:

- **Flag files** - writes `%TEMP%\claude-zellij-flags\<tab>.json` when a session
  needs a human, so `scripts/zj-claude-tab.ps1 -Waiting` can jump straight
  there.
- **Status bar** - keeps a per-project state map and pipes one coloured line to
  the zjstatus `status` widget.
- **Live records** - on `SessionStart` writes
  `%LOCALAPPDATA%\ZellijTerminal\live\<key>.json`, and deletes it on
  `SessionEnd`. That is how a session started in any folder ends up registered in
  `zt` without you doing anything.

The event name comes from `hook_event_name` on stdin, so every event registers
the identical command - no per-event arguments.

**Why the live record is written inline rather than by calling `zt`.** Importing
a module costs more than this entire hook; the module lives on the pwsh 7 module
path while this runs under Windows PowerShell 5.1; and this code is on the
latency path of every session start. So it writes one small file and lets `zt`
do the thinking later.

The file is named by a hash of the normalised `cwd`, because a workspace's
identity is its directory - two folders called `api` are two workspaces, and
renaming a tab must not orphan its records. `Get-ZtKey` in the module computes
the same value the same way. **Those two implementations must not drift**; there
is no shared code between them because the hook cannot afford to load any.

## Event mapping

| Event | Meaning | Flag |
|---|---|---|
| `Notification` | Claude is asking for something | set |
| `PermissionRequest` | permission prompt on screen | set |
| `Stop` | finished responding, your turn | set |
| `SubagentStop` | subagent finished | set |
| `UserPromptSubmit` | you replied | cleared |
| `PreToolUse` / `PostToolUse` | working | cleared |
| `SessionStart` | idle | cleared |
| `SessionEnd` | gone | removed |

## Why exec form

Providing `args` selects **exec form**: the executable is spawned directly, with
no shell involved. No quoting problems, no path mangling.

**Shell form** (omitting `args`) defaults to **Git Bash** on Windows unless you
set `"shell": "powershell"`. Exec form sidesteps the question entirely.

Caveat: exec form cannot launch `.cmd` or `.bat` shims. `powershell.exe` is a
real executable, so it's fine.

## Why powershell.exe rather than pwsh.exe

`powershell.exe` (Windows PowerShell 5.1) ships with Windows and is always
present. The hook script is deliberately 5.1-compatible - no ternary `? :`, no
`??`, no `&&`/`||`. Switch to `pwsh.exe` if you prefer, but keep the script
compatible either way or the hook fails silently in the background.

## Performance

Every hook invocation is a PowerShell process start. Measured:

| engine | per invocation |
|---|---|
| `powershell.exe` (5.1) | ~478 ms |
| `pwsh.exe` (7.6.4) | ~600 ms |

pwsh is consistently *slower* to start, so `powershell.exe` is the right choice
on speed as well as on availability.

`PreToolUse` and `PostToolUse` fire on **every tool call**, so registering both
adds **~956 ms per tool call** - roughly 19 seconds on a twenty-tool turn. Do
not register them. The other seven fire a handful of times per turn, costing
about a second per turn regardless of how much work Claude does, and they carry
every colour that matters: `Stop`, `Notification`, `PermissionRequest`,
`UserPromptSubmit`.

## Never wait on `zellij pipe`

With zjstatus listening, **`zellij pipe` never returns** - it holds the pipe
open streaming plugin output that never ends. Every invocation form blocks.
Claude Code waits for its hooks, so a blocking call here freezes Claude on every
event.

The script therefore starts the pipe process, allows 200 ms, and kills it. With
no plugin listening zellij exits on its own in ~50 ms, so the cap costs nothing
in that case. If you rewrite this part, keep that property - `Test-Setup.ps1`
checks for it.

## When it fails, it now says so

The hook runs detached with output going nowhere, so its failures used to be
completely invisible. It writes one line per failure to
`%TEMP%\claude-zellij-hook.log`, and `zt check` reports that file under **Hook
errors**. `ZT_HOOK_DEBUG=1` logs successful events too. It still exits 0 whatever
happens — a hook that fails a session is worse than a hook that fails.

An empty log with nothing happening usually means the hook is not registered for
that project. It fires only where it is registered:

```powershell
.\install.ps1            # this repo only
.\install.ps1 -Global    # every project, merged into your existing settings
```

## A trap when testing

Zellij locates its session IPC under `%TEMP%`. Redirecting `TEMP` to sandbox a
test makes `zellij pipe` fail fast with exit 1 instead of connecting, so the
hook appears to work when it is really doing nothing. Test the pipe path with
the real `TEMP`.

## Test without Claude Code

```powershell
'{"hook_event_name":"Stop","cwd":"C:/code/api"}' |
  powershell.exe -NoProfile -File C:\tools\claude-zj-hook.ps1

dir $env:TEMP\claude-zellij-flags
```

A file called `claude-api.json` should appear.
