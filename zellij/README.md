# Zellij setup

## Install what goes where

| File here | Goes to |
|---|---|
| `config.kdl` | `%APPDATA%\Zellij\config\config.kdl` |
| `layouts/claude.kdl.template` | `%APPDATA%\Zellij\config\layouts\claude.kdl` |

**Note the `config` level**, which is easy to get wrong and fails silently: put
the layout one directory up and Zellij simply never finds it. Confirm the real
paths with `zellij setup --check` — on Windows they are **not**
`~/.config/zellij`, which is what most documentation says.

The layout ships as a `.template` because it carries absolute paths. `install.ps1`
renders it; by hand, copy it to the destination above and replace `{{PLUGINS}}`
with your Zellij plugin directory and `{{REPO}}` with this clone. Left
unreplaced they do not error - you get a status bar that never loads and a tab
in the wrong directory.

## Windows Terminal profile

Add to `profiles.list` in `settings.json`:

```json
{
    "guid": "{2c8f9487-fc5d-4d12-bd32-44f30f9f2d72}",
    "name": "Claude (Zellij)",
    "commandline": "zellij.exe attach --create claude",
    "startingDirectory": "%USERPROFILE%"
}
```

`attach --create` reuses the session if it's running and creates it otherwise,
so closing the tab doesn't lose state and reopening drops you back in.

**One profile, not all of them.** See `docs/02-decisions.md` D4.

## Per-tab working directories

The rendered `claude.kdl` gives each named tab its own `cwd`. Precedence, most
specific first:

```
pane cwd  ->  tab cwd  ->  layout cwd  ->  directory you launched from
```

Two other kinds of "remembering" come free: new panes inherit the focused pane's
current directory, and Zellij serialises sessions — an exited session still
appears in `zellij list-sessions` and resurrects with tabs, names and
directories intact.

## Tab naming is load-bearing

Tabs must be named `claude-<leaf>` where `<leaf>` is the last path segment of
the project directory. `C:/code/api` -> `claude-api`.

Both `hooks/claude-zj-hook.ps1` (which derives the tab name from the `cwd` on
stdin) and `scripts/zj-claude-tab.ps1` (which filters on the prefix) depend on
this. Change the convention in one place and you must change it in all three.

## Rough edges — 0.44.0 is the first native Windows release

| Issue | Effect |
|---|---|
| [#4938](https://github.com/zellij-org/zellij/issues/4938) | Config is in `%APPDATA%\Zellij\config\`, not where the docs say |
| [#4938](https://github.com/zellij-org/zellij/issues/4938) | `default_shell` may be ignored entirely |
| [#5052](https://github.com/zellij-org/zellij/issues/5052) | **cwd breaks when `default_shell` is `pwsh.exe`** |
| [#4964](https://github.com/zellij-org/zellij/issues/4964) | `-NoLogo` in the pwsh profile breaks shell detection |
| [#4897](https://github.com/zellij-org/zellij/issues/4897) | Inconsistent shell environment at session start |

#5052 is the one most likely to bite here, since per-tab `cwd` is exactly what
the claude layout relies on. Test one tab before writing out all of them; if
it fails, try `powershell.exe` or leave `default_shell` unset.

## Smoke test

With Claude Code sitting at a prompt inside the session, from a **different**
window:

```powershell
zellij --session claude action write 13
```

If the prompt accepts, the whole focus-free premise holds and everything else is
wiring.
