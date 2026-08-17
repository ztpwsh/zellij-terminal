# Background

Why this rig is shaped the way it is, and what Zellij's CLI actually does as
opposed to what it looks like it does.

Several comments in the code cite this page rather than repeat themselves —
`scripts/zj-claude-project.ps1`, `scripts/README.md` — so what follows is
evidence, not opinion. Versions: Zellij 0.44.3, Windows 11, PowerShell 7.6.4
with Windows PowerShell 5.1 for hooks, zjstatus v0.24.0.

---

## Where this came from

None of this began as a multiplexer project. It began as a macro pad.

The want was small and specific: approve or reject a Claude Code permission
prompt, and move between sessions, using four physical keys — **without having
to be looking at the terminal**. A SayoDevice `1_3P` was programmed to emit four
inert chords and the first version drove Windows Terminal directly.

That is where it stopped, on a fact that turns out to be structural:

> **A macro pad is a plain HID keyboard. It sends keystrokes to whatever window
> currently has focus, and knows nothing about applications.**

So anything app-aware, or anything that works while you are looking elsewhere,
needs software on the host intercepting the keys — and then that software has to
get a keystroke into a terminal it is not looking at. On Windows Terminal it
cannot. `ControlSend` posts `WM_KEYDOWN`/`WM_KEYUP` to a window handle, and
Windows Terminal renders through DirectX/XAML and reads the focused-window
keyboard path rather than posted messages. There is no public API for injecting
a keystroke into an unfocused Terminal; anything claiming otherwise is
describing a different terminal.

`pad/macropad.ahk` is what that dead end actually looked like, and it is kept as
the record: activate the terminal, send the key, hand focus back — about 100 ms,
with a visible flash. It works. It just cannot ever stop being a focus change.

**Zellij is what removes the requirement rather than working around it.** Its
CLI addresses the *shell*, not the *window*:

```powershell
zellij --session claude action write 13     # 13 = Enter, into an unfocused pane
```

No focus change, no flash, and it works while the terminal is minimised. Zellij
0.44.0 is the first release to run natively on Windows, which is what makes this
viable without WSL — the project is only possible at all because of a release
that landed shortly before it started.

Everything downstream is a consequence of that one substitution. Addressing the
shell means addressing it by *something*, and what Zellij offers is tab names,
which is why the naming convention is load-bearing in three components at once.
Injection is fire-and-forget with no reply, which is why the hook and its flag
files exist — the sessions have to raise their own hands, because nothing can be
asked. And the rest of this page is the tax: what the CLI does when you use it
this way, as opposed to what it looks like it does.

One alternative is worth recording as closed. **A Zellij plugin cannot listen
for the pad.** Plugin `Key` events fire only while the user is focused on that
plugin's own pane, and the API exposes no path for input originating outside the
terminal — so the pad's keystrokes reach a plugin only when Zellij is already
focused, which is the case that needed no machinery in the first place.

---

## Actions act on the FOCUSED tab, not a named one

This is the one that shapes the most code.

`zellij action close-tab` closes the **focused** tab. There is no `--name` and
no `--tab`.

**`rename-tab` was the exception, and this file said otherwise for months.** It
takes `-t <id>`, and with it the rename targets that tab and leaves focus alone.
Retested on 0.44.3 by renaming tab 0 from tab 2 and reading `current-tab-info`
afterwards: the name changed, the focus did not move. The earlier note here
claimed the flag was cosmetic; it was wrong, and the tab activity glyph is built
on the corrected version. The **bare** form does still rename whatever is
focused, so `-t` is not optional — a background hook without it would rename the
tab you are looking at.

Zellij 0.44.3 also has `close-tab-by-id`, `go-to-tab-by-id` and
`rename-tab-by-id`, which take a *stable* id. Nothing in this rig uses them yet;
they are the honest replacement for the focus-then-act dance below, and are the
first thing to reach for when the palette's silent Close-tab is investigated.

The consequence is unavoidable and it is a user-visible one: **any operation on
a named tab has to focus that tab first, so it moves you.** There is no way over
the CLI to close, rename or type into tab X while you go on looking at tab Y.

That is why:

- `scripts/zj-claude-project.ps1 -Remove` calls `go-to-tab-name` before
  `close-tab`, and says so rather than pretending your view stays put. Two
  guards make the focus-then-close safe: the name must match `claude-*`, so a
  stray argument cannot close something that is not a project tab; and the tab
  list is captured before and after, with a loud error if anything other than
  exactly the intended tab disappeared. Zellij tabs carry no metadata to stamp,
  so the name prefix is the only ownership marker available — weaker than an id,
  hence the second check.
- `-NoFocus` on `-Add` prints a warning instead of doing what it says.
  `new-tab` always focuses what it creates and returning afterwards is not
  reliable, so the flag is honest about being partial.
- The hook renames **only with `-t <id>`, and only a tab it has positively
  identified.** It appends an activity glyph — `claude-web-api ~` — so the tab
  itself says what its session is doing. There is still no pane-to-tab lookup on
  the CLI (`dump-layout` shows tabs and panes but no pane ids), so it resolves
  its tab by name, walking up from the cwd to the first ancestor that has one,
  and renames nothing when that finds nothing. Colour cannot go in the name:
  zjstatus substitutes `{name}` as plain text, so markup there prints
  literally. Colour is still piped to zjstatus, which is also what
  the project it was ported from does —
  [thoo/claude-code-zellij-status](https://github.com/thoo/claude-code-zellij-status),
  bash and jq rather than PowerShell, reaching the same conclusion by a
  different route.
- `Send-ZtKeys` in `module/ZellijTerminal/Private/Core.ps1` focuses and then
  *waits* before typing (see "Injection" below).

---

## One session with many tabs, not many sessions

`zellij list-sessions` and `zellij action query-tab-names` are two different
levels: sessions are separate servers, each with its own tabs and its own
clients; tabs live inside one session. Everything in the module works inside a
single session, `claude` — `module/ZellijTerminal/Public/Sessions.ps1` is the
only file that goes a level up.

The reasons are all consequences of how the CLI addresses things:

- **Injection is per session, and needs a client attached to that session.**
  One session means one attached window makes every project reachable. Several
  sessions would each need their own attached client, and an unattached one
  fails silently (below).
- **The pad addresses a session by name.** Every remap written by
  `module/ZellijTerminal/Public/Pad.ps1` bakes `--session claude` into its
  arguments; keys 1 and 2 are literally `zellij --session claude action write
  13` and `... write 27`. One session name is the whole address. Per-session
  bindings would need per-session keys.
- **Tab navigation does not cross sessions.** `go-to-tab-name`,
  `query-tab-names` and the cycling in `scripts/zj-claude-tab.ps1` all operate
  within one session, so "jump to whoever is waiting" only means anything if
  everyone is in the same one.
- **The status bar is per session.** `hooks/claude-zj-hook.ps1` keys its shared
  state map on `ZELLIJ_SESSION_NAME` and pipes one line built from every project
  in it. Split the projects across sessions and you split the bar.

The cost is that the two levels are easy to confuse. `zt close` closes a tab and
never touches a session, so tabs will never appear in `list-sessions`; and
killing the managed session takes every Claude session in it down at once, which
is why `Remove-ZellijTerminalSession` refuses that one without `-Force`. Strays
accumulate at the session level quietly — `session_serialization` keeps exited
sessions around to resurrect, and a mistyped command creates a whole new server
named after a random animal — so `zt sessions` exists purely to make that level
visible.

---

## Every client mirrors, and the grid is pinned to the smallest

A **client** is a terminal viewing a session, and a session can have several.
That is not a second session and it is not a second view of different things:
same tabs, same panes, same content. Every keystroke lands in all of them.

Three consequences, in ascending order of how long they cost to work out:

- **Each client carries its own focus.** `write` and `write-chars` go to the
  pane focused *in the client that receives them*, so an injected keystroke can
  land somewhere you are not looking — including a live Claude session in the
  middle of something.
- **The grid is sized to the smallest attached client.** Widening one window
  changes nothing while a smaller one is attached, and the text never reflows.
  This presents as "Zellij cannot reflow its scrollback", which is a dead end:
  reflow works perfectly, and returns the moment one client is left.
- **Nothing downstream can tell two clients apart.** They are the same session
  by every handle this rig has, so no command can prefer "the one you are
  looking at".

The diagnosis is the same command that answers the empty case above:

```powershell
zellij --session claude action list-clients
```

More than one row is the answer. Zero rows means nothing is attached and every
action is a silent no-op; the header prints either way, and so does exit code 0.

On Windows the usual cause of an unwanted second client is Windows Terminal's
`"firstWindowPreference": "persistedWindowLayout"`, which restores the saved
layout when the first window opens — and here that saved layout is a window
already running `zellij attach`. `zt check` reports it. See
`docs/03-troubleshooting.md` for the fix.

---

## Tab names are the addressing scheme

`go-to-tab-name` is the addressing there is. So the tab name has to be
derivable, identically, by three things that never talk to each other:

- `hooks/claude-zj-hook.ps1` derives it from the `cwd` Claude Code passes on
  stdin;
- `scripts/zj-claude-project.ps1` derives it from the directory being added;
- `scripts/zj-claude-tab.ps1` filters on it when cycling.

All three build `<prefix><leaf>` — `C:/code/api` becomes `claude-api` — so they
agree by construction and adding a project needs no configuration anywhere.
`zellij/README.md` puts it plainly: change the convention in one place and you
must change it in all three.

**The prefix is what makes the namespace.** Cycling with `-Pattern 'claude*'`
skips your shell, editor and log tabs, where Zellij's own `go-to-next-tab`
includes everything. The hook recognises its own tabs by it. `-Remove` refuses
anything outside it. The single startup tab in
`zellij/layouts/claude.kdl.template` is called `home` precisely so the pad walks
past it.

Two things follow that are easy to miss:

- **A name is not an identity.** A workspace's identity is its directory: the
  registry key is a hash of the normalised path, computed the same way by
  `Get-ZtKey` in `module/ZellijTerminal/Private/Core.ps1` and inline by the
  hook. Two folders called `api` are two workspaces, and renaming a tab must not
  orphan its records.
- **Duplicate leaves collide.** `F:\a\api` and `F:\b\api` both want
  `claude-api`, and `go-to-tab-name` then picks one arbitrarily — the pad
  answers the wrong session, silently. Registration warns and assigns a distinct
  name; `-TabName` / `-Name` overrides it explicitly.

Name matching is done longest-first (`scripts/zj-claude-tab.ps1`) so `claude1`
never wins over `claude10` by being a prefix of it, and `Wait-ZtFocus` matches
`name: <tab>` followed by `id:` rather than a bare substring, for the same
reason.

The prefix is Zellij bookkeeping only. `claude --name` gets the tab name with
the prefix stripped — `web-api`, not `claude-web-api` — because that
label shows in the prompt box, the `/resume` picker and on mobile, where the
prefixed form reads as though the tool were part of the project's name. Nothing
matches on it, so they are free to differ. On Windows it is not an address
either: cross-session messaging by `@name` is not offered here, confirmed by
`CLAUDE_CODE_MESSAGING_SOCKET` being unset on Claude Code 2.1.232.

---

## Almost everything here fails silently and still exits 0

This is the property that governs how the whole rig is tested and documented.

**With no client attached to the session**, `write`, `write-chars`,
`go-to-tab-name`, `close-tab` and `dump-screen` are all silent no-ops **that
still exit 0**. Injected bytes vanish. `zellij list-sessions` shows
the session perfectly healthy and `zt` lists every workspace, while nothing on
screen and no key press does anything. The whole diagnosis is one command:

```powershell
zellij --session claude action list-clients
```

An empty table under the header is the answer. A minimised or unfocused window
is fine; a closed one is not. Every command that injects — `Stop-ZellijTerminal`,
`Start-ZellijTerminal` into an existing tab — calls `Test-ZtClientAttached`
first and refuses, rather than reporting a success that did not happen.

**`current-tab-info` fails the opposite way.** It only answers for a client
attached to the session. Called from outside — which is exactly how the macro
pad calls it — it prints `No active tab found for current client` and exits 2:
non-empty output meaning the *opposite* of success. Any check testing "did I get
output?" reports a false pass, and the error text gets pattern-matched against
tab names if you do not exclude it explicitly. That is why the `%TEMP%` state
file in `scripts/zj-claude-tab.ps1` is the primary mechanism in pad use rather
than a rarely-hit fallback, and why `-Remove` verifies the close by comparing the
tab list before and after instead of trusting the focus report.

The same shape recurs at every other layer, which is why `zt check`
(`scripts/Test-Setup.ps1`) tests each one separately:

- A KDL parse error in a layout loaded via `--session` is swallowed and reported
  as `Session 'claude' not found`, which sends you hunting in the wrong place.
- A tab whose `cwd` does not exist does not error; Zellij falls back silently and
  you get a tab in the wrong directory.
- PowerToys Keyboard Manager appears not to honour quoted arguments: keys 1 and
  2 fired while keys 3 and 4 did nothing at all, with the identical command line
  working when pasted into a shell, and no error anywhere. Its engine also reads
  its config at **start**, not on change, so remaps can go on working after
  being deleted.
- The pad's scripts run in a hidden window, so anything they print goes nowhere.
  When `zellij` was not on PATH in the de-elevated launch environment, every call
  returned null and the script died on a `.Trim()`; the only symptom was a key
  that did nothing. `zj-claude-tab.ps1` now takes `-ZellijExe` and fails loudly
  on the first line instead.
- The hook runs detached under `powershell.exe` with output going nowhere. Every
  `catch` in it used to be empty, so a malformed payload meant no flag, no
  status, no trace — and every downstream symptom pointed at the pad, or Zellij,
  or the layout. It now writes one line per failure to
  `%TEMP%\claude-zellij-hook.log`, which `zt check` reports.
- With zjstatus listening, `zellij pipe` **never returns** — it holds the pipe
  open streaming plugin output that never ends. Claude Code waits for its hooks,
  so a blocking call there freezes Claude on every event. The hook
  starts the process, allows 200 ms and kills it.

The rule that falls out: an exit code is not evidence here. Prove the effect —
a client row, a tab that disappeared, a flag file on disk.

---

## Panes inherit the zellij *server's* environment

A Zellij pane does not inherit the environment of whatever asked for the tab. It
inherits the environment of the **zellij server process**, for as long as that
server lives. Three variables make this expensive.

**`TERM` and `COLORTERM` are both empty** in a Zellij pane on Windows, verified
with a probe pane. Claude Code and most TUIs read them to decide whether colour
is supported, so without help everything renders black and white inside Zellij
while looking fine in a bare terminal.

**`CLAUDE_CODE_CHILD_SESSION`** — if the server was ever started from inside a
Claude Code session, every pane in that session inherits the child marker and
Claude reports "Transcript saving is off".

**`NO_COLOR`** — the same trap with a louder symptom, and the reason this
section exists. Claude Code sets `NO_COLOR=1` for every command it runs so its
tool output comes back as plain text. Install this rig *by asking Claude to* —
which `docs/05-usage.md` and the `zt-setup` skill actively recommend — and `zac`
runs inside that environment, so the server it starts inherits `NO_COLOR=1` and
hands it to every pane. `NO_COLOR` is honoured *before* `TERM` and `COLORTERM`
are looked at, so setting those two is silently pointless and the entire session
renders black and white: Claude Code loses its colours and a themed prompt loses
its styling, which together read convincingly as "this is cmd, not pwsh".

Two defences, deliberately overlapping:

- `Connect-ZellijTerminal` (`module/ZellijTerminal/Public/Control.ps1`) scrubs
  both variables from its own environment before `attach --create`, because that
  call is what starts the server when the session does not exist yet. This fixes
  the source. They are restored afterwards, so only the child is affected.
- The **pane prelude** clears them again per pane, in
  `scripts/zj-claude-project.ps1` and in the layout template. This is the belt to
  that braces, since the server may have been started by hand.

The prelude does *not* cover a tab opened with Zellij's own keybinding: that uses
`new_tab_template`, a bare pane with no prelude, so it inherits the server's copy
and misbehaves while every other tab looks fine. That is the worst shape of bug
this rig produces, because the working tabs argue that the setup is sound.

Clearing `NO_COLOR` in the pane costs a deliberate global `NO_COLOR` its effect
inside these tabs only. That is the intended trade: the point of the rig is
coloured TUIs.

---

## Injection: how a prompt gets answered

There is no way to ask Zellij for the PID running in a pane, and no way to signal
one. What there is, is injection — Zellij's own IPC, from outside, with the
terminal as nothing but a viewport:

```powershell
zellij --session claude action write 13      # 13 = Enter
zellij --session claude action write 27      # 27 = Esc
```

That is the whole premise, and it is the smoke test in `zellij/README.md`: if
Claude Code accepts a prompt when you run that from a different window, the rest
is wiring. It works with the terminal unfocused or minimised, at roughly 60 ms
per call — which is why pad keys 1 and 2 call `zellij.exe` directly rather than
paying a PowerShell start of ~500 ms to forward two bytes.
`write` takes a raw byte, `write-chars` a string, and 0.44 also has `send-keys`
with named keys.

Keys 1 and 2 target no tab at all: they write to whatever is focused in the
session, which is exactly the semantics wanted for "answer the thing I am looking
at". Anything aimed at a *named* tab pays the focused-tab tax from the top of
this page, and that is where the care goes:

- `Send-ZtKeys` focuses with `go-to-tab-name`, then calls `Wait-ZtFocus`, which
  polls `current-tab-info` until the right tab is really focused and returns
  `$false` if it never is. `go-to-tab-name` returns when the request is *queued*,
  not when the switch has happened, and `write` goes to whatever pane is focused
  **when the bytes arrive**. Losing that race sends Ctrl+C into a different tab —
  very possibly a live Claude session mid-turn. That was observed during
  development: the first `zt stop` reported success and the target was still
  running.
- Callers treat a focus failure as a failure. `Stop-ZellijTerminal` refuses to
  report a stop it could not deliver.
- `Stop` sends Ctrl+C **twice**, 300 ms apart: Claude Code treats a single Ctrl+C
  as "clear the input line" and only exits on the second. At a bare prompt the
  second one is harmless.
- The pane runs `pwsh -NoExit`, so a stop leaves a prompt in the right directory
  rather than a vanished tab — which is what lets `zt restart` simply type the
  command back in.

`--pane-id` does exist on `write`, `write-chars` and `send-keys`. It is not used
here, because nothing maps a tab name to a pane id, and a hook has no way to
learn its own pane — the same missing lookup that rules out renaming tabs.

---

## Where the evidence lives

| Claim | Read |
|---|---|
| focused-tab actions, and the guards around removal | `scripts/zj-claude-project.ps1`, `scripts/README.md` |
| why the hook never renames | `hooks/claude-zj-hook.ps1` |
| sessions versus tabs | `module/ZellijTerminal/Public/Sessions.ps1`, `docs/03-troubleshooting.md` |
| name derivation, and the collision | `zellij/README.md`, `docs/06-workspaces.md` |
| silent no-ops, focus races, attached-client checks | `module/ZellijTerminal/Private/Core.ps1`, `module/ZellijTerminal/Public/Control.ps1` |
| mirrored clients, and the grid pinned to the smallest | `scripts/Test-Setup.ps1`, `module/ZellijTerminal/Public/Control.ps1` |
| server environment inheritance | `zellij/layouts/claude.kdl.template`, `module/ZellijTerminal/Public/Control.ps1` |
| what each layer is checked for | `scripts/Test-Setup.ps1` |
