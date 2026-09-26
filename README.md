> [!WARNING]
> 🚧 **TRAILER / UNDER ACTIVE DEVELOPMENT** 🚧  
> *PowerDo is currently a work-in-progress project by **glastfin**. Features, syntax, and behaviors are subject to change as development evolves.*

---

# PowerDo

**Glastfin Edition** — a full-screen, keyboard-driven todo manager for your terminal.
Pure PowerShell 7, zero dependencies, flat dark UI.

```
 * POWERDO                                                    GLASTFIN EDITION
  crafted by GlaStFiN  .  Task List  .  1/5 done
┌───────────────────────────────────────────────────────┬──────────────────────┐
│ (A) ship PowerDo v1 +release @desk due:2026-09-28     │ DETAIL               │
│ (A) review PR #42 +release @work                      │                      │
│ (x) buy groceries +home @errands                      │ Status:   Open       │
│ ( ) water the plants +home                            │ Priority: A          │
└───────────────────────────────────────────────────────┴──────────────────────┘
 NORMAL  .  theme:MutedSlate  .  density:comfortable  .  sort:priority
 >  ?: help   ,: settings   U: uninstall   q: quit
```

![demo](demo.gif)

## Features

- **Plain-text tasks** in todo.txt / done.txt (todo.txt-style syntax: `(A) priority`, `+project`, `@context`, `due:YYYY-MM-DD`)
- **Views**: task list, archive, help overlay, settings overlay, detail & filter sidebars
- **Filtering**: search `/`, filter by project `fp` / context `fc`, cycle sort `S`
- **Bulk editing**: visual mode with multi-select, complete/delete
- **50-level undo** (`u`)
- **Fuzzy due dates** — `due:tomorrow`, `due:eom`, `due:next_monday`, or open the `du` prompt and type `next month`, `by friday`, `sep 15`, `30/9`, `in 3 weeks`… anything from today/tomorrow to end-of-month/weekday math, normalized to `due:YYYY-MM-DD`
- **Urgency coloring** — overdue dates go red, today/tomorrow bold amber, detail sidebar shows `tomorrow` / `overdue by 3 days`
- **4 themes** (MutedSlate, Dawn, Nord, Matrix) × **3 densities** (compact, comfortable, cozy)
- **Line numbers**, done-task visibility toggle, persistent `config.json`
- **In-app uninstall** — remove the app from inside the app

## Requirements

- Windows
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`)

## Install

**Option A — single click:** double-click `Install PowerDo.cmd` and answer the prompts.

**Option B — unattended:**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-PowerDo.ps1 -Auto
```

The installer asks a question at each step:

1. permission gate
2. detects an existing install (offers repair/reinstall)
3. install folder (default `%LOCALAPPDATA%\Programs\PowerDo`)
4. copies the app
5. unblocks downloaded files (MotW)
6. sets a permissive per-user execution policy (skipped if already fine)
7. registers the `powerdo` PowerShell profile alias
8. optionally adds `powerdo.cmd` + your folder to user PATH (works in PowerShell 7, Windows PowerShell and cmd)
9. optionally whitelists the folder in Defender / adds a desktop shortcut

## Usage

Open a **new** terminal and type:

```
powerdo
```

| Keys | Action |
|---|---|
| `j` / `k`, arrows | move |
| `gg` / `G` | top / bottom |
| `Ctrl-d` / `Ctrl-u` | half page |
| `n` | add task (`call mom +home @phone due:2026-10-01`) |
| `e` / `i` | edit selected |
| `x` | toggle complete |
| `dd` | delete selected |
| `p` | cycle priority (A→B→C→none) |
| `c` / `+` | add context / project |
| `du` | set due date — fuzzy prompt (`today`, `tmr`, `mon`, `eom`, `30`, `sep 15`, `clear`) |
| `dt` / `dw` | due today / due +7 days (quick) |
| `u` | undo |
| `/` | search |
| `fp` / `fc` | filter by project / context |
| `S` | cycle sort |
| `v` + `space` | visual mode, multi-select |
| `A` | archive all done |
| `a` | archive view (`u` un-archive, `dd` delete forever) |
| `[` / `]` | filter / detail sidebar |
| `L` | line numbers |
| `T` / `D` | theme / density |
| `,` | settings (`U` = uninstall) |
| `?` | help overlay |
| `Esc` | clear filters |
| `q` | quit |

## Data

Everything lives in `%LOCALAPPDATA%\PowerDo`:

- `todo.txt` — open tasks
- `done.txt` — completed tasks
- `config.json` — theme, density, sort, layout preferences

## Uninstall

**From inside the app:** `,` → `U` → `y` (keep data) or `d` (delete data).

**From a terminal:**

```powershell
pwsh -File "$env:LOCALAPPDATA\Programs\PowerDo\Uninstall-PowerDo.ps1"
```

Both remove the profile alias, PATH entry, shortcut, Defender whitelist and program files.

## License

[MIT](LICENSE) — crafted by GlaStFiN.
