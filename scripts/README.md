# Scripts

These are the implementation. For day-to-day use there is the `zt` module —
`..\module\ZellijTerminal`, installed with `..\install.ps1` — so you type `zt
start api` from anywhere instead of a script path. See `docs/06-workspaces.md`.

What `zt` calls down to here for:

| Command | Script it calls |
|---|---|
| `zt start` (new tab) | `zj-claude-project.ps1 -Add -TabName -Command` |
| `zt close` | `zj-claude-project.ps1 -Remove` |
| `zt next` / `prev` / `go` | `zj-claude-tab.ps1` |
| `zt check` | `Test-Setup.ps1` |
| `zt diag` | `Collect-Diagnostics.ps1` |

`zt start` into an existing tab, `zt stop` and `zt restart` do not call a script
— they focus the tab and inject keystrokes, which has no script equivalent.

**Two callers deliberately bypass the module.** The macro pad runs
`powershell.exe -NoProfile -File <script>` — a key press already costs ~458 ms
and a module import would be added to every one of them. The hook runs under
Windows PowerShell 5.1, whose module path is `Documents\WindowsPowerShell\`,
not where this installs. Both call the scripts directly and neither cares
whether the module is installed. That is why the hook writes its own live
record with twenty lines of inline code rather than calling into `zt`.

## `Test-Setup.ps1`

Checks every layer independently and prints a pass/fail table. **Run this
first** whenever something breaks - "the pad doesn't work" has at least six
distinct causes across four layers, and they need different fixes.

```powershell
.\Test-Setup.ps1
.\Test-Setup.ps1 -Session claude -Prefix claude-
```

Fix the **lowest** failing layer first. A broken layer makes everything above it
look broken too.

Add a check here whenever you add a capability.

## `Collect-Diagnostics.ps1`

Writes one file describing what is actually on this machine, for reading
somewhere else.

```powershell
.\Collect-Diagnostics.ps1                      # -> %TEMP%\zt-diag-<stamp>.md
.\Collect-Diagnostics.ps1 -ParseLayout         # also ask Zellij to parse the layout
.\Collect-Diagnostics.ps1 -NoRedact -Path .\bundle.md
```

**It is not a second `Test-Setup.ps1`.** That one asks whether each layer works
and answers with a verdict. This one asks what is on the machine and answers
with the bytes, because the case it exists for is a *clean* `zt check` on a rig
that does not work.

The reason that case exists at all: every check in `Test-Setup.ps1` asks whether
a file is **there**, and the files that decide whether this rig starts are
generated per machine. `%APPDATA%\Zellij\config\layouts\claude.kdl` carries an
absolute plugin path and an absolute `cwd`, both substituted at install time
from `zellij/layouts/claude.kdl.template`. A layout that exists, parses, and
points its plugin at a file that is not there passes every question the layer
check knows how to ask, and gives you a session with no status bar. An
unreplaced `{{PLUGINS}}` does the same and takes the tab's working directory
with it. Neither prints anything.

So it reads those files out verbatim, and where there is a source to compare
against it **regenerates what the installer should have written and diffs**.
Judging the diff is the reader's job, with the repo in front of them.

The bundle opens with a **Signals** list — observations worth reading first,
never verdicts — then the evidence for each. It ends with the `zt check` output,
so a clean table and a signal can be read side by side.

Redacted by default (user name, device name, profile path), because the file is
written to be sent. It changes nothing on the machine; `-ParseLayout` is the one
exception and says what it does: `--layout` cannot be combined with `--session`,
so the throwaway session it creates cannot be named in advance, and the session
list is captured before and after so only what appeared gets deleted.

## `zj-claude-tab.ps1`

Move between Zellij tabs matching a pattern.

```powershell
.\zj-claude-tab.ps1 -Waiting                 # jump to whoever needs you
.\zj-claude-tab.ps1 -Direction next          # cycle claude-* tabs only
.\zj-claude-tab.ps1 -Direction prev -Session claudexxx -Pattern "claude*"
```

`-Waiting` is the one worth binding to a key. It reads the flag files the hook
writes and jumps to the session that has been waiting longest, walking the queue
on repeated presses. With nothing waiting it falls back to cycling.

`-Direction` skips every tab that doesn't match the pattern, so your shell,
editor and log tabs stay out of the rotation.

Both modes determine the current tab from `current-tab-info`, matching longest
names first so `claude1` never wins over `claude10` by being a prefix of it. If
that call fails, they fall back to a state file in `%TEMP%`.

**That fallback matters more than it looks.** `current-tab-info` only answers
for a client attached to the session. Called from outside — which is exactly
what the macro pad does — it prints `No active tab found for current client`
and exits 2. That is non-empty output meaning the *opposite* of success, so any
check testing "did I get output?" reports a false pass. The `%TEMP%` state file
is the real mechanism here, not a rarely-used backup.

## `zj-claude-project.ps1`

Add, remove and list project tabs at runtime, so `claude.kdl` doesn't need
editing every time a project starts or finishes.

```powershell
.\zj-claude-project.ps1 -Add .                      # from inside the project
.\zj-claude-project.ps1 -Add C:\code\api
.\zj-claude-project.ps1 -Add C:\code\foo -Launch  # and start Claude in it
.\zj-claude-project.ps1 -List
.\zj-claude-project.ps1 -Remove api         # or claude-api
.\zj-claude-project.ps1 -Remove api -WhatIf # dry run
```

Every mutating operation supports `-WhatIf` and `-Confirm`. Worth using on
`-Remove` at least once — it closes a tab and whatever is running in it.

### From your Windows Terminal profiles

If you already bookmark project directories with
a bookmarks module, that list is
the same list this wants:

```powershell
.\zj-claude-project.ps1 -FromBookmarks
.\zj-claude-project.ps1 -FromBookmarks -Filter 'web*' -Launch
.\zj-claude-project.ps1 -FromBookmarks -WhatIf        # see what it would add
```

Existing tabs are detected and skipped, so it is safe to re-run as you add
bookmarks.

**The tab is named after the directory, not the bookmark.** A bookmark called
`web-frontend` pointing at `C:\code\api` becomes
`claude-api`. That is deliberate and load-bearing: the hook derives the
tab name from the `cwd` Claude Code reports, so a name taken from the bookmark
label would not match the flag file and `-Waiting` would never find it.

The tab is named `claude-<leaf>` from the directory's leaf folder — the same
derivation `claude-zj-hook.ps1` applies to the `cwd` Claude Code passes on
stdin, and the same names `zj-claude-tab.ps1` cycles. All three agree by
construction, so adding a project needs no configuration anywhere else.

`-List` marks any tab whose hook has flagged it as waiting, with the event and
how long it has been waiting.

**On `-Remove`.** `zellij action close-tab` closes the *focused* tab — there is
no `--name` — the same trap as `rename-tab` in `docs/00-background.md`. So
removal has to focus the target first, which changes what you are looking at.
Unavoidable over the CLI. Two guards make that safe:

- the name must match `claude-*`, so a typo cannot close a tab that is not a project;
- the tab list is compared before and after, and the script errors loudly if
  anything other than exactly the intended tab disappeared.

`-NoFocus` on `-Add` is honoured only as far as the CLI allows: `new-tab`
always focuses what it creates, and returning afterwards is not reliable, so
the flag prints a warning rather than pretending.

## When nothing happens at all

Check for an attached client **first**:

```powershell
zellij --session claude action list-clients
```

An empty table under the header means no terminal is attached to the session.
In that state `write`, `write-chars`, `go-to-tab-name`, `close-tab` and
`dump-screen` are all silent no-ops **that still exit 0** — so there is no
error anywhere to lead you to it. A minimised or unfocused window is
fine; a closed one is not.

## Compatibility

Everything here targets **Windows PowerShell 5.1** as well as PowerShell 7.
No ternary `? :`, no `??`, no `&&`/`||` chains. The hook runs under
`powershell.exe`, so this is a hard requirement, not a preference.

Note that a profile-bookmarking module deliberately makes the opposite choice — it is
PowerShell 7 only and uses `?:` freely. The constraint here comes from Claude
Code hooks launching `powershell.exe`; it is not a house style, and code
borrowed from that module needs converting.

