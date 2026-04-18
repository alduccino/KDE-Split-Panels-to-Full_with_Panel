# 🏝 Island Panels for KDE Plasma 6

A bash + Python installer that splits your KDE Plasma panel into three independent floating "islands", with automatic switching to a unified full-width panel when any window is maximized.

![Plasma 6](https://img.shields.io/badge/KDE_Plasma-6.x-blue?logo=kde)
![Fedora](https://img.shields.io/badge/Fedora-tested-blue?logo=fedora)

---

## What it looks like

**Normal state** — three floating islands at the bottom:

```
╭──────────────╮        ╭──────────────────────╮        ╭──────────────────╮
│  🚀 Launcher │        │  App1  App2  App3 …  │        │  🔊 📶 🔋  14:32 │
╰──────────────╯        ╰──────────────────────╯        ╰──────────────────╯
← left                          center                            right →
```

**Window maximized** — one unified full-width panel:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  🚀  │  App1  App2  App3  …                              │  🔊 📶 🔋  14:32 │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## How it works

No C++ plugins, no patching Plasma source. Three standard techniques composed together:

1. **`create-panels.py`** writes panel containments directly to `plasma-org.kde.plasma.desktop-appletsrc` using `kwriteconfig6` — bypassing `evaluateScript`, which does not expose `createPanel()` in Plasma 6's D-Bus scripting context.

2. **`install.sh`** restarts plasmashell to load the new containments, then applies alignment, lengthMode, and floating properties via `evaluateScript`.

3. **`kwin/main.js`** — a KWin script loaded via `loadScript` + `start()` D-Bus calls — listens for maximize events through three independent layers (workspace signal, per-window signal, and a 1-second polling timer as a guaranteed fallback), then calls `evaluateScript` with the correct `callDBus` signature to toggle panel visibility.

When hidden, panels are moved to the opposite screen edge (`location=top`) with `hiding=autohide`. The autohide trigger zone at the top edge (y=0 of the screen) is unreachable during normal usage since all UI elements (browser tabs, title bars, menus) sit inside window frames, never at the raw screen edge.

---

## Requirements

| Package | Purpose | Install |
|---|---|---|
| `qt6-qttools-common` | `qdbus6` — D-Bus communication | `sudo dnf install qt6-qttools-common` |
| `kf6-kconfig` | `kwriteconfig6` — KConfig writing | `sudo dnf install kf6-kconfig` |
| `plasma-workspace` | `kstart6`, `kquitapp6` | included with Plasma |
| `python3` | panel config writer | included with Fedora |

---

## Install

```bash
git clone https://github.com/alduccino/island-panels-kde
cd island-panels-kde
chmod +x install.sh
./install.sh install
```

Then **right-click your existing full-width panel → Edit Panel → Remove Panel**.  
The three islands and the hidden unified panel are already loaded underneath it.

**Test the maximize toggle:**
```bash
./install.sh toggle-test
```

---

## Uninstall

```bash
./install.sh uninstall
```

Restores your original panel layout from the pre-install backup and removes the KWin script and systemd service.

---

## Configuration

Edit **`config.env`** — single source of truth for both the panel creator and the KWin script:

```bash
PANEL_HEIGHT=44              # panel height in px
PANEL_LOCATION="bottom"      # "bottom" or "top"
MARGIN_EDGE=8                # px gap from left/right screen edges
LAUNCHER_WIDGET="org.kde.plasma.kickoff"   # or "org.kde.plasma.kicker"
TASKS_WIDGET="org.kde.plasma.icontasks"    # or "org.kde.plasma.taskmanager"
ADD_CLOCK=true               # include digital clock in right island
```

Re-apply after any change:
```bash
./install.sh install
```

---

## Commands

```bash
./install.sh install       # create panels + KWin maximize toggle
./install.sh uninstall     # restore original layout from backup
./install.sh toggle        # enable/disable maximize behavior only
./install.sh toggle-test   # manually trigger island↔unified switch (2s delay)
./install.sh reload-kwin   # reload KWin script without restarting anything
./install.sh verify-kwin   # check KWin script is loaded and active
./install.sh diagnose      # print all panel properties via evaluateScript
./install.sh status        # show installation state and panel IDs
```

---

## Files

```
install.sh          Main installer / manager
config.env          Shared configuration (edit this)
create-panels.py    Writes panel containments via kwriteconfig6
kwin/
  main.js           KWin script — maximize toggle logic
  metadata.json     KWin script package metadata
```

---

## Troubleshooting

**KWin script not triggering on maximize**

```bash
./install.sh verify-kwin   # check isScriptLoaded=true
./install.sh reload-kwin   # reload without restarting
```

If `isScriptLoaded=false` after reload, log out and back in — the systemd user service (`island-panels-kwin.service`) will re-activate the script 8 seconds after login.

**Panels created but wrong width/alignment**

```bash
./install.sh diagnose      # shows each panel's id, lengthMode, hiding, floating
./install.sh install       # re-runs the evaluateScript fix pass
```

**Restore original layout**

```bash
./install.sh uninstall
```

Backups are stored at:
- `~/.config/island-panels-backup.appletsrc`
- `~/.config/island-panels-backup.kwinrc`

---

## Known limitations

| | |
|---|---|
| Maximize toggle animation | Panel swap is near-instant (~100ms) but not interpolated. True animation would require a C++ Plasma containment plugin. |
| Multi-monitor | Any fully maximized window on any screen triggers the switch. Per-screen logic would require additional KWin scripting. |
| Hidden panel peek | When panels are hidden at the top edge (autohide), hovering y=0 of the screen reveals them briefly. In practice this never happens accidentally since all UI elements sit inside window frames. |
| Session restore | KWin scripts require `loadScript + start()` after each login. The included systemd user service handles this automatically. |

---

## Technical notes

### Why not `evaluateScript` + `createPanel`?

`createPanel()` is only available during Plasma's startup scripting phase. The `evaluateScript` D-Bus method runs scripts in a runtime JS context where `createPanel` is undefined. This is why `create-panels.py` writes directly to `plasma-org.kde.plasma.desktop-appletsrc` using `kwriteconfig6`.

### Why `loadScript` + `start()`, not just `reconfigure`?

`kwin reconfigure` re-reads `kwinrc` and enqueues newly enabled scripts, but does **not** call `start()`. Without `start()`, the script's JS is never executed — signals never connect, the timer never runs. The installer explicitly calls both `loadScript` and `start()` via D-Bus after writing the plugin flag.

### Why `callDBus('org.kde.PlasmaShell', 'evaluateScript', ...)` (split args)?

The `callDBus()` function in KWin's JS runtime takes `(service, path, interface, method, ...args)` as separate arguments. Passing `'org.kde.PlasmaShell.evaluateScript'` as a single string merges interface and method into a non-existent interface name — KWin drops the call silently.

---

## License

MIT
