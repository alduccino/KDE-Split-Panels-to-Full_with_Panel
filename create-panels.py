#!/usr/bin/env python3
"""
create-panels.py — Island Panels direct KConfig writer (v1.4).

Changes vs v1.3:
  • All keys are written via kwriteconfig6 instead of Python configparser.
    This guarantees the exact KConfig binary/text format that Plasma expects.
  • floating is written as --type bool true  (was: floating=1, incorrect)
  • panelLengthMode: islands=1 (Fit), unified=0 (Fill)
    Values from PanelView::LengthMode enum: Fill=0, Fit=1, Custom=2
  • A post-install evaluateScript pass in install.sh sets p.lengthMode='fit'
    on islands by ID as a belt-and-suspenders fix.

Usage:
  python3 create-panels.py create  [--launcher W] [--tasks W] [--height N]
                                   [--margin N] [--location bottom|top] [--clock true|false]
  python3 create-panels.py remove  [--islands] [--unified] [--all]
  python3 create-panels.py status
  python3 create-panels.py maxid       # prints current max containment ID
"""

import configparser, json, os, re, subprocess, sys

CONFIG_FILE = "plasma-org.kde.plasma.desktop-appletsrc"
CONFIG_PATH = os.path.expanduser(f'~/.config/{CONFIG_FILE}')
MARKER      = os.path.expanduser('~/.config/island-panels-ids.json')

# Qt::Alignment flags (written by PanelView::setAlignment as int)
QT_LEFT   = 1    # Qt::AlignLeft
QT_CENTER = 132  # Qt::AlignCenter = Qt::AlignHCenter|Qt::AlignVCenter
QT_RIGHT  = 2    # Qt::AlignRight

LOCATION = {'bottom': 4, 'top': 3}

# PanelView::LengthMode (panelview.h): Fill=0, Fit=1, Custom=2
LENGTH_FILL = 0
LENGTH_FIT  = 1

# PanelView::VisibilityMode: NormalPanel=0, AutoHide=1
VISIBILITY_NORMAL   = 0
VISIBILITY_AUTOHIDE = 1


# ─── kwriteconfig6 wrapper ───────────────────────────────────────────────────
def kwrite(groups, key, value, ktype=None):
    """
    Write a single key to the Plasma config via kwriteconfig6.
    groups: list/tuple of group path strings, e.g. ['Containments', '101', 'General']
    ktype:  optional --type argument ('bool', 'int', 'string', 'path')
    """
    cmd = ['kwriteconfig6', '--file', CONFIG_FILE]
    for g in groups:
        cmd += ['--group', str(g)]
    if ktype:
        cmd += ['--type', ktype]
    cmd += ['--key', key, str(value)]
    subprocess.run(cmd, check=True, capture_output=True)


# ─── ID management ───────────────────────────────────────────────────────────
def current_max_id():
    """Parse the plasma config and return the highest numeric ID found."""
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CONFIG_PATH, encoding='utf-8')
    m = 100
    for s in cfg.sections():
        for n in re.findall(r'\d+', s):
            m = max(m, int(n))
    return m


def next_free_id():
    return current_max_id() + 1


# ─── Panel builder ───────────────────────────────────────────────────────────
def add_panel(location, alignment, offset,
              length_mode, visibility_mode, widgets, thickness=44, floating=True):
    """
    Creates one panel containment + its applets using kwriteconfig6.
    floating=True  for island panels (rounded floating style)
    floating=False for unified panel (classic full-width bar, no rounding)
    """
    cid = next_free_id()   # re-read max after every panel so IDs don't collide
    aid = cid + 1

    base = ('Containments', cid)
    kwrite(base, 'activityId',     '')
    kwrite(base, 'formfactor',     '2')
    kwrite(base, 'immutability',   '1')
    kwrite(base, 'lastScreen',     '0')
    kwrite(base, 'location',       str(location))
    kwrite(base, 'plugin',         'org.kde.panel')
    kwrite(base, 'wallpaperplugin','org.kde.image')

    gen = ('Containments', cid, 'General')
    kwrite(gen, 'alignment',       str(alignment))
    kwrite(gen, 'floating',        'true' if floating else 'false', 'bool')
    kwrite(gen, 'offset',          str(offset))
    kwrite(gen, 'panelLengthMode', str(length_mode)) # 0=Fill, 1=Fit
    kwrite(gen, 'panelVisibility', str(visibility_mode)) # 0=normal, 1=autohide
    kwrite(gen, 'thickness',       str(thickness))

    for widget in widgets:
        applet = ('Containments', cid, 'Applets', aid)
        kwrite(applet, 'immutability', '1')
        kwrite(applet, 'plugin',       widget)
        aid += 1

    print(f'  Created containment {cid}  alignment={alignment}'
          f'  lengthMode={length_mode}  visibility={visibility_mode}'
          f'  widgets={widgets}')
    return cid


# ─── Remove ──────────────────────────────────────────────────────────────────
def remove_containment_ids(id_list):
    """Delete all [Containments][N][...] sections for each ID in id_list."""
    cfg = configparser.RawConfigParser()
    cfg.optionxform = str
    cfg.read(CONFIG_PATH, encoding='utf-8')

    removed = 0
    for cid in id_list:
        pattern = rf'^Containments\]\[{cid}(\]|$)'
        for s in list(cfg.sections()):
            if re.match(pattern, s):
                cfg.remove_section(s)
                removed += 1

    with open(CONFIG_PATH, 'w', encoding='utf-8') as f:
        cfg.write(f, space_around_delimiters=False)

    print(f'Removed {removed} config sections for IDs: {id_list}')


# ─── Marker helpers ──────────────────────────────────────────────────────────
def load_ids():
    if os.path.exists(MARKER):
        try:
            with open(MARKER) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_ids(ids):
    with open(MARKER, 'w') as f:
        json.dump(ids, f, indent=2)


# ─── Commands ────────────────────────────────────────────────────────────────
def cmd_create(opts):
    loc      = LOCATION.get(opts.get('location', 'bottom'), 4)
    margin   = int(opts.get('margin', 8))
    launcher = opts.get('launcher', 'org.kde.plasma.kickoff')
    tasks    = opts.get('tasks',    'org.kde.plasma.icontasks')
    height   = int(opts.get('height', 44))
    clock    = opts.get('clock', 'true').lower() not in ('false', '0', 'no')

    right_w   = ['org.kde.plasma.systemtray']
    unified_w = [launcher, tasks, 'org.kde.plasma.systemtray']
    if clock:
        right_w.append('org.kde.plasma.digitalclock')
        unified_w.append('org.kde.plasma.digitalclock')

    print('Creating island panels via kwriteconfig6…')

    # ── Islands: Fit mode (shrink to content), always visible ────
    lid = add_panel(loc, QT_LEFT,   margin, LENGTH_FIT,  VISIBILITY_NORMAL,   [launcher], height)
    cid = add_panel(loc, QT_CENTER, 0,      LENGTH_FIT,  VISIBILITY_NORMAL,   [tasks],    height)
    rid = add_panel(loc, QT_RIGHT,  margin, LENGTH_FIT,  VISIBILITY_NORMAL,   right_w,    height)

    # ── Unified: Fill mode (full width), auto-hidden by default ──
    uid = add_panel(3,   QT_CENTER, 0,      LENGTH_FILL, VISIBILITY_AUTOHIDE, unified_w,  height, floating=False)  # location=top so it starts hidden above top edge

    ids = load_ids()
    ids['islands'] = [lid, cid, rid]
    ids['unified'] = [uid]
    save_ids(ids)

    print(f'\nIsland IDs  : {lid}, {cid}, {rid}  (panelLengthMode=1 = Fit, panelVisibility=0 = visible)')
    print(f'Unified ID  : {uid}  (panelLengthMode=0 = Fill, panelVisibility=1 = autohide)')
    print(f'IDs saved to: {MARKER}')


def cmd_remove(opts):
    ids     = load_ids()
    targets = []

    if opts.get('all'):
        targets = ids.get('islands', []) + ids.get('unified', [])
        ids = {}
    else:
        if opts.get('islands'): targets += ids.pop('islands', [])
        if opts.get('unified'): targets += ids.pop('unified', [])

    if not targets:
        print('Nothing to remove (no recorded IDs).')
        return

    remove_containment_ids(targets)
    save_ids(ids)


def cmd_status(_opts):
    ids = load_ids()
    if ids:
        print(f"Islands  : {ids.get('islands', [])}  — Fit mode, always visible")
        print(f"Unified  : {ids.get('unified', [])}  — Fill mode, autohide when idle")
    else:
        print('No island panel IDs recorded.')


def cmd_maxid(_opts):
    print(current_max_id())


# ─── Arg parser ──────────────────────────────────────────────────────────────
def parse_opts(argv):
    opts, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith('--'):
            key = a[2:]
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                opts[key] = argv[i + 1]; i += 2
            else:
                opts[key] = 'true'; i += 1
        else:
            i += 1
    return opts


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)

    cmd  = sys.argv[1]
    opts = parse_opts(sys.argv[2:])

    dispatch = {
        'create':  cmd_create,
        'remove':  cmd_remove,
        'status':  cmd_status,
        'maxid':   cmd_maxid,
    }
    fn = dispatch.get(cmd)
    if fn:
        fn(opts)
    else:
        print(f'Unknown command: {cmd}'); sys.exit(1)
