#!/usr/bin/env bash
# ================================================================
#  install.sh — Island Panels for KDE Plasma 6  (v2.0)
#
#  Changes vs v1.5:
#   • Fixed metadata.json: removed X-Plasma-API-Minimum-Version
#     (that's a Plasma applet field — KWin silently ignores scripts
#     with unrecognised metadata keys in some builds)
#   • KWin script now loaded via two complementary methods:
#       1. kpackagetool6 --type KWin/Script (proper package install)
#       2. loadScript D-Bus call → start() call (immediate activation
#          without needing a KWin restart; this was the missing step —
#          reconfigure alone doesn't call start() for new scripts)
#   • systemd user service: island-panels-kwin.service
#     Re-runs loadScript+start() after each login so the script
#     survives KWin/session restarts
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="$SCRIPT_DIR/config.env"
PY_CREATOR="$SCRIPT_DIR/create-panels.py"
KWIN_SRC_DIR="$SCRIPT_DIR/kwin"

PLASMA_CONFIG="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
KWINRC="$HOME/.config/kwinrc"
KWIN_INSTALL_DIR="$HOME/.local/share/kwin/scripts/islandpanels"
SYSTEMD_DIR="$HOME/.local/share/systemd/user"
SERVICE_NAME="island-panels-kwin.service"
IDS_FILE="$HOME/.config/island-panels-ids.json"

BACKUP_PLASMA="$HOME/.config/island-panels-backup.appletsrc"
BACKUP_KWINRC="$HOME/.config/island-panels-backup.kwinrc"
MARKER_FILE="$HOME/.config/island-panels-installed"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'

info() { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
warn() { echo -e "${YEL}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }
sep()  { echo -e "${BLD}─────────────────────────────────────────────${RST}"; }

detect_qdbus() {
    if command -v qdbus6 &>/dev/null; then echo "qdbus6"
    elif command -v qdbus &>/dev/null; then echo "qdbus"
    else die "qdbus not found. Install: sudo dnf install qt6-qttools-common"; fi
}
detect_kstart()   { command -v kstart6   &>/dev/null && echo "kstart6"   || echo "kstart5";   }
detect_kquitapp() { command -v kquitapp6 &>/dev/null && echo "kquitapp6" || echo "kquitapp5"; }
detect_kwriteconfig() {
    if command -v kwriteconfig6 &>/dev/null; then echo "kwriteconfig6"
    elif command -v kwriteconfig5 &>/dev/null; then echo "kwriteconfig5"
    else die "kwriteconfig not found. Install: sudo dnf install kf6-kconfig"; fi
}

load_config() {
    [[ -f "$CFG_FILE" ]] || die "config.env not found at $CFG_FILE"
    source "$CFG_FILE"
}

read_ids() {
    local key="$1"
    python3 -c "
import json
try:
    d = json.load(open('$IDS_FILE'))
    print(','.join(str(i) for i in d.get('$key', [])))
except: print('')
" 2>/dev/null
}

run_python_creator() {
    local clock_arg
    clock_arg="$( [[ "${ADD_CLOCK:-true}" == "true" ]] && echo "true" || echo "false" )"
    python3 "$PY_CREATOR" create \
        --launcher "${LAUNCHER_WIDGET:-org.kde.plasma.kickoff}" \
        --tasks    "${TASKS_WIDGET:-org.kde.plasma.icontasks}"  \
        --height   "${PANEL_HEIGHT:-44}"                         \
        --margin   "${MARGIN_EDGE:-8}"                           \
        --location "${PANEL_LOCATION:-bottom}"                   \
        --clock    "$clock_arg"
}

apply_evaluatescript_fix() {
    local qdbus island_ids unified_ids result
    qdbus="$(detect_qdbus)"
    island_ids="$(read_ids islands)"
    unified_ids="$(read_ids unified)"
    [[ -z "$island_ids" && -z "$unified_ids" ]] && { warn "No IDs — skipping fix."; return; }

    # Parse individual island IDs from the comma-separated list.
    # Order matches create-panels.py: left_id, center_id, right_id
    local left_id center_id right_id
    IFS=',' read -r left_id center_id right_id <<< "$island_ids"

    info "Applying alignment + lengthMode + hiding via evaluateScript…"
    info "  Left   id=$left_id  → alignment=left,   lengthMode=fit,  hiding=none"
    info "  Center id=$center_id → alignment=center, lengthMode=fit,  hiding=none"
    info "  Right  id=$right_id  → alignment=right,  lengthMode=fit,  hiding=none"
    info "  Unified ids=[$unified_ids] → alignment=center, lengthMode=fill, hiding=autohide"

    local panel_h="${PANEL_HEIGHT:-44}"
    local fix_js
    fix_js="$(cat <<JSEOF
var leftId=${left_id};
var centerId=${center_id};
var rightId=${right_id};
var ui=[${unified_ids}];
var h=${panel_h};
var ps=panels();
var log='panels='+ps.length;
for(var i=0;i<ps.length;i++){
  var p=ps[i];
  log+=' id='+p.id;
  if(p.id===leftId){
    p.location='bottom'; p.alignment='left'; p.lengthMode='fit'; p.floating=true; p.height=h; p.hiding='none';
    log+='(left→bottom/fit)';
  }
  if(p.id===centerId){
    p.location='bottom'; p.alignment='center'; p.lengthMode='fit'; p.floating=true; p.height=h; p.hiding='none';
    log+='(center→bottom/fit)';
  }
  if(p.id===rightId){
    p.location='bottom'; p.alignment='right'; p.lengthMode='fit'; p.floating=true; p.height=h; p.hiding='none';
    log+='(right→bottom/fit)';
  }
  if(ui.indexOf(p.id)>=0){
    p.location='top'; p.alignment='center'; p.lengthMode='fill'; p.floating=false; p.height=h; p.hiding='autohide';
    log+='(unified→top/autohide)';
  }
}
print(log);
JSEOF
)"

    result="$("$qdbus" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$fix_js" 2>&1)" || true
    echo "$result" | grep -q 'panels=' \
        && ok "Fix applied: $result" \
        || warn "evaluateScript output: ${result:-<empty>}"
}

restart_plasmashell() {
    local kquit kstart
    kquit="$(detect_kquitapp)"; kstart="$(detect_kstart)"
    info "Restarting plasmashell…"
    "$kquit" plasmashell 2>/dev/null || pkill -x plasmashell 2>/dev/null || true
    sleep 1
    nohup "$kstart" plasmashell &>/dev/null &
    sleep 4
    ok "plasmashell restarted."
}

# ─── Install KWin script ─────────────────────────────────────────
# Uses two methods to ensure the script is both persistently installed
# (kpackagetool6 + kwinrc flag) and immediately active (loadScript + start).
install_kwin_script() {
    local kwriteconfig qdbus island_ids unified_ids
    kwriteconfig="$(detect_kwriteconfig)"
    qdbus="$(detect_qdbus)"
    island_ids="$(read_ids islands)"
    unified_ids="$(read_ids unified)"

    [[ -z "$island_ids" ]] && { warn "No island IDs."; island_ids="0"; }
    [[ -z "$unified_ids" ]] && { warn "No unified IDs."; unified_ids="0"; }

    # ── Step 1: Install script files ──────────────────────────
    info "Installing KWin script files…"
    mkdir -p "$KWIN_INSTALL_DIR/contents/code"
    cp "$KWIN_SRC_DIR/metadata.json" "$KWIN_INSTALL_DIR/metadata.json"
    local panel_h_kwin="${PANEL_HEIGHT:-44}"
    sed \
        -e "s|@@ISLAND_IDS@@|${island_ids}|g" \
        -e "s|@@UNIFIED_IDS@@|${unified_ids}|g" \
        -e "s|@@PANEL_HEIGHT@@|${panel_h_kwin}|g" \
        "$KWIN_SRC_DIR/main.js" \
        > "$KWIN_INSTALL_DIR/contents/code/main.js"
    ok "Script files installed → $KWIN_INSTALL_DIR"

    # ── Step 2: Register with kpackagetool6 (if available) ───
    if command -v kpackagetool6 &>/dev/null; then
        info "Registering with kpackagetool6…"
        kpackagetool6 --type KWin/Script \
            --upgrade "$KWIN_INSTALL_DIR" 2>/dev/null || \
        kpackagetool6 --type KWin/Script \
            --install "$KWIN_INSTALL_DIR" 2>/dev/null || true
        ok "kpackagetool6 registration done."
    else
        warn "kpackagetool6 not found — skipping package registration."
        info "Install with: sudo dnf install plasma-framework"
    fi

    # ── Step 3: Enable in kwinrc ──────────────────────────────
    "$kwriteconfig" --file kwinrc --group Plugins \
                    --key islandpanelsEnabled true
    ok "Plugin enabled in kwinrc."

    # ── Step 4: Tell KWin to re-read its config ───────────────
    "$qdbus" org.kde.KWin /KWin reconfigure 2>/dev/null || true
    sleep 1

    # ── Step 5: loadScript → start() (THE MISSING STEP) ──────
    # reconfigure loads the script into KWin's registry but does NOT
    # call start(). Without start(), the script's JS is never executed.
    info "Calling loadScript + start() via D-Bus to activate immediately…"

    local script_path="$KWIN_INSTALL_DIR/contents/code/main.js"
    local script_id
    script_id="$("$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.loadScript \
        "$script_path" "islandpanels" 2>&1)" || script_id=""

    if [[ "$script_id" =~ ^[0-9]+$ && "$script_id" -gt 0 ]]; then
        ok "loadScript returned ID=$script_id."
    else
        info "loadScript output: '${script_id}' (script may already be loaded)"
    fi

    # start() runs all loaded-but-not-yet-started scripts
    "$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.start 2>/dev/null && ok "start() called." || \
        warn "start() call failed (may already be running)"

    # ── Step 6: Verify ───────────────────────────────────────
    sleep 1
    local loaded
    loaded="$("$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.isScriptLoaded "islandpanels" 2>/dev/null || echo "unknown")"

    if [[ "$loaded" == "true" ]]; then
        ok "KWin script is ACTIVE (isScriptLoaded=true). Timer is running."
    else
        warn "isScriptLoaded=$loaded — script may need a session restart."
        info "Try: ./install.sh reload-kwin"
    fi
}

uninstall_kwin_script() {
    local kwriteconfig qdbus
    kwriteconfig="$(detect_kwriteconfig)"
    qdbus="$(detect_qdbus)"
    info "Removing KWin script…"
    "$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.unloadScript "islandpanels" 2>/dev/null || true
    "$kwriteconfig" --file kwinrc --group Plugins \
                    --key islandpanelsEnabled false 2>/dev/null || true
    "$qdbus" org.kde.KWin /KWin reconfigure 2>/dev/null || true
    if command -v kpackagetool6 &>/dev/null; then
        kpackagetool6 --type KWin/Script \
            --remove islandpanels 2>/dev/null || true
    fi
    rm -rf "$KWIN_INSTALL_DIR"
    ok "KWin script removed."
}

# ─── systemd user service: re-activates KWin script after login ──
install_systemd_service() {
    local qdbus
    qdbus="$(detect_qdbus)"
    local script_path="$KWIN_INSTALL_DIR/contents/code/main.js"

    info "Installing systemd user service for KWin script reload…"
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/$SERVICE_NAME" <<UNIT
[Unit]
Description=Island Panels — reload KWin script after session start
After=plasma-kwin_wayland.service graphical-session.target
Requires=graphical-session.target

[Service]
Type=oneshot
# Give KWin a few seconds to fully initialize after login
ExecStartPre=/usr/bin/sleep 8
ExecStart=/bin/bash -c '\\
    QDBUS=\$(command -v qdbus6 || command -v qdbus); \\
    \$QDBUS org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript \\
        "${script_path}" "islandpanels" 2>/dev/null; \\
    \$QDBUS org.kde.KWin /Scripting org.kde.kwin.Scripting.start 2>/dev/null; \\
    '
RemainAfterExit=yes

[Install]
WantedBy=graphical-session.target
UNIT

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME" 2>/dev/null && \
        ok "systemd service enabled: $SERVICE_NAME" || \
        warn "Could not enable systemd service (will still work this session)"
    systemctl --user start  "$SERVICE_NAME" 2>/dev/null || true
}

uninstall_systemd_service() {
    systemctl --user stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$SERVICE_NAME"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd service removed."
}

# ─── Reload KWin script (useful after session restart) ───────────
do_reload_kwin() {
    sep; echo -e "${BLD}  Reload KWin Script${RST}"; sep
    local qdbus
    qdbus="$(detect_qdbus)"
    local script_path="$KWIN_INSTALL_DIR/contents/code/main.js"

    [[ -f "$script_path" ]] || die "Script not found at $script_path. Run install first."

    info "Unloading previous instance…"
    "$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.unloadScript "islandpanels" 2>/dev/null || true
    sleep 1

    info "Loading script…"
    local script_id
    script_id="$("$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.loadScript "$script_path" "islandpanels" 2>&1)" || true
    info "loadScript → '$script_id'"

    "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.start 2>/dev/null \
        && ok "start() called." || warn "start() may have failed."

    sleep 1
    local loaded
    loaded="$("$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.isScriptLoaded "islandpanels" 2>/dev/null || echo "unknown")"
    [[ "$loaded" == "true" ]] \
        && ok "Script is ACTIVE. Maximize a window to test." \
        || warn "Still not active (isScriptLoaded=$loaded). Try logging out and back in."
    sep
}

# ════════════════════════════════════════════════════════════════
#  INSTALL
# ════════════════════════════════════════════════════════════════
do_install() {
    sep
    echo -e "${BLD}  Island Panels — Install (v2.0)${RST}"
    sep

    pgrep -x plasmashell &>/dev/null || die "plasmashell is not running."
    command -v python3       &>/dev/null || die "python3 not found."
    command -v kwriteconfig6 &>/dev/null || die "kwriteconfig6 not found."
    [[ -f "$PY_CREATOR" ]] || die "create-panels.py not found."

    load_config

    if [[ -f "$MARKER_FILE" ]]; then
        warn "Already installed."
        read -rp "  Reinstall? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
        python3 "$PY_CREATOR" remove --all 2>/dev/null || true
        uninstall_systemd_service 2>/dev/null || true
    fi

    [[ -f "$PLASMA_CONFIG" ]] && { cp "$PLASMA_CONFIG" "$BACKUP_PLASMA"
        ok "Plasma config backed up → $BACKUP_PLASMA"; }
    [[ -f "$KWINRC" ]] && { cp "$KWINRC" "$BACKUP_KWINRC"
        ok "kwinrc backed up → $BACKUP_KWINRC"; }

    echo
    run_python_creator
    echo

    restart_plasmashell

    echo
    apply_evaluatescript_fix

    echo
    install_kwin_script

    echo
    install_systemd_service

    echo "$(date --iso-8601=seconds)" > "$MARKER_FILE"

    sep
    echo
    echo -e "${GRN}${BLD}  Done!${RST}"
    echo
    echo -e "  ${BLD}1.${RST} Right-click your old panel → Edit Panel → ${RED}Remove Panel${RST}"
    echo -e "  ${BLD}2.${RST} Maximize any window to test the toggle"
    echo
    echo -e "  If the toggle doesn't fire, run: ${CYN}./install.sh reload-kwin${RST}"
    echo -e "  For full diagnostics:           ${CYN}./install.sh verify-kwin${RST}"
    sep
}

# ════════════════════════════════════════════════════════════════
#  UNINSTALL
# ════════════════════════════════════════════════════════════════
do_uninstall() {
    sep; echo -e "${BLD}  Uninstall${RST}"; sep
    [[ -f "$BACKUP_PLASMA" ]] || die "No backup found."
    read -rp "  Restore original layout? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
    uninstall_kwin_script
    uninstall_systemd_service 2>/dev/null || true
    cp "$BACKUP_PLASMA" "$PLASMA_CONFIG" && ok "Plasma config restored."
    [[ -f "$BACKUP_KWINRC" ]] && cp "$BACKUP_KWINRC" "$KWINRC" && ok "kwinrc restored."
    rm -f "$IDS_FILE"
    restart_plasmashell
    rm -f "$MARKER_FILE"
    ok "Uninstalled."
    sep
}

# ════════════════════════════════════════════════════════════════
#  VERIFY-KWIN
# ════════════════════════════════════════════════════════════════
do_verify_kwin() {
    sep; echo -e "${BLD}  Verify KWin Script${RST}"; sep
    local qdbus
    qdbus="$(detect_qdbus)"

    echo -e "${BLD}kwinrc flag:${RST}"
    kreadconfig6 --file kwinrc --group Plugins --key islandpanelsEnabled \
        2>/dev/null | sed 's/^/  /' || echo "  (not set)"

    echo
    echo -e "${BLD}Script files:${RST}"
    if [[ -f "$KWIN_INSTALL_DIR/contents/code/main.js" ]]; then
        ok "Present. Injected IDs:"
        grep "^var ISLAND_IDS\|^var UNIFIED_IDS" \
            "$KWIN_INSTALL_DIR/contents/code/main.js" | sed 's/^/  /'
    else
        warn "Not found at $KWIN_INSTALL_DIR"
    fi

    echo
    echo -e "${BLD}isScriptLoaded:${RST}"
    local loaded
    loaded="$("$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.isScriptLoaded "islandpanels" 2>&1 || echo "error")"
    echo "  → $loaded"

    if [[ "$loaded" == "true" ]]; then
        ok "Script is ACTIVE. The 1-second polling timer is running."
        echo "  Maximize a window — it should switch within 1 second."
    else
        warn "Script NOT active."
        echo
        echo "  Fix options (try in order):"
        echo "  a) ./install.sh reload-kwin        (reload without restart)"
        echo "  b) Log out and log back in          (systemd service will reload it)"
        echo "  c) ./install.sh install             (full reinstall)"
    fi

    echo
    echo -e "${BLD}systemd service:${RST}"
    systemctl --user status "$SERVICE_NAME" --no-pager -l 2>/dev/null | head -8 | sed 's/^/  /' || \
        echo "  (service not installed)"
    sep
}

# ════════════════════════════════════════════════════════════════
#  TOGGLE TEST
# ════════════════════════════════════════════════════════════════
do_toggle_test() {
    sep; echo -e "${BLD}  Toggle Test${RST}"; sep
    local qdbus island_ids unified_ids
    qdbus="$(detect_qdbus)"
    island_ids="$(read_ids islands)"
    unified_ids="$(read_ids unified)"
    [[ -z "$island_ids" || -z "$unified_ids" ]] && die "No panel IDs. Run install first."

    local ph="${PANEL_HEIGHT:-44}"
    echo "  → Switching to UNIFIED in 2 s… (islands→top/autohide, unified→bottom)"
    sleep 2
    "$qdbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "var ii=[${island_ids}];var ui=[${unified_ids}];var h=${ph};var ps=panels();for(var i=0;i<ps.length;i++){var p=ps[i];if(ii.indexOf(p.id)>=0){p.location='top';p.hiding='autohide';}if(ui.indexOf(p.id)>=0){p.location='bottom';p.floating=false;p.height=h;p.hiding='none';}}" \
        2>&1 | grep -v '^$' | sed 's/^/  /' || true
    echo "  → One full-width panel at bottom. Islands gone to top (hover top edge to check)."

    echo "  → Switching back to ISLANDS in 3 s… (unified→top/autohide, islands→bottom)"
    sleep 3
    "$qdbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "var ii=[${island_ids}];var ui=[${unified_ids}];var h=${ph};var ps=panels();for(var i=0;i<ps.length;i++){var p=ps[i];if(ii.indexOf(p.id)>=0){p.location='bottom';p.floating=true;p.height=h;p.hiding='none';}if(ui.indexOf(p.id)>=0){p.location='top';p.hiding='autohide';}}" \
        2>&1 | grep -v '^$' | sed 's/^/  /' || true
    echo "  → Three island panels at bottom. Unified gone to top."
    sep
}

# ════════════════════════════════════════════════════════════════
#  DIAGNOSE / TOGGLE KWIN / STATUS / MENU
# ════════════════════════════════════════════════════════════════
do_diagnose() {
    sep; echo -e "${BLD}  Diagnose${RST}"; sep
    local qdbus; qdbus="$(detect_qdbus)"
    echo -e "${BLD}1. Panel IDs:${RST}"
    python3 "$PY_CREATOR" status 2>/dev/null | sed 's/^/  /' || echo "  none"
    echo
    echo -e "${BLD}2. All panels via evaluateScript:${RST}"
    "$qdbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        'var ps=panels();var o="panels="+ps.length;for(var i=0;i<ps.length;i++){var p=ps[i];o+="\n  id="+p.id+" lm="+p.lengthMode+" hiding="+p.hiding+" floating="+p.floating;}print(o);' \
        2>&1 | sed 's/^/  /' || true
    echo
    echo -e "${BLD}3. KWin script active:${RST}"
    "$qdbus" org.kde.KWin /Scripting \
        org.kde.kwin.Scripting.isScriptLoaded "islandpanels" 2>/dev/null \
        | sed 's/^/  /' || echo "  (query failed)"
    sep
}

toggle_kwin() {
    sep; echo -e "${BLD}  Toggle KWin maximize script${RST}"; sep
    local kwriteconfig qdbus cur
    kwriteconfig="$(detect_kwriteconfig)"; qdbus="$(detect_qdbus)"
    cur="$(kreadconfig6 --file kwinrc --group Plugins --key islandpanelsEnabled \
           --default false 2>/dev/null || echo false)"
    if [[ "$cur" == "true" ]]; then
        "$kwriteconfig" --file kwinrc --group Plugins --key islandpanelsEnabled false
        "$qdbus" org.kde.KWin /KWin reconfigure 2>/dev/null || true
        ok "Maximize toggle DISABLED."
    else
        "$kwriteconfig" --file kwinrc --group Plugins --key islandpanelsEnabled true
        "$qdbus" org.kde.KWin /KWin reconfigure 2>/dev/null || true
        do_reload_kwin
    fi
    sep
}

do_status() {
    sep; echo -e "${BLD}  Status${RST}"; sep
    [[ -f "$MARKER_FILE" ]] && ok "Installed: $(cat "$MARKER_FILE")" || info "Not installed."
    python3 "$PY_CREATOR" status 2>/dev/null || true
    [[ -f "$BACKUP_PLASMA" ]]    && ok "Plasma backup : $BACKUP_PLASMA" || warn "No Plasma backup."
    [[ -d "$KWIN_INSTALL_DIR" ]] && ok "KWin script   : installed"       || warn "KWin script   : not found."
    systemctl --user is-active "$SERVICE_NAME" &>/dev/null \
        && ok "systemd service: active" || warn "systemd service: inactive"
    sep
}

show_menu() {
    sep
    echo -e "${BLD}  🏝  Island Panels for KDE Plasma 6  (v2.0)${RST}"
    sep
    echo "  1) Install       — create panels + KWin maximize toggle"
    echo "  2) Uninstall     — restore original layout"
    echo "  3) Toggle KWin   — enable/disable maximize behavior"
    echo "  4) Toggle test   — manually switch island↔unified"
    echo "  5) Reload KWin   — reload script without restart"
    echo "  6) Verify KWin   — check script is loaded and active"
    echo "  7) Diagnose      — show all panel properties"
    echo "  8) Status"
    echo "  0) Exit"
    sep
    read -rp "  Choice: " choice
    case "$choice" in
        1) do_install    ;;  2) do_uninstall   ;;
        3) toggle_kwin   ;;  4) do_toggle_test ;;
        5) do_reload_kwin;;  6) do_verify_kwin ;;
        7) do_diagnose   ;;  8) do_status      ;;
        0) exit 0        ;;
        *) warn "Invalid."; show_menu ;;
    esac
}

case "${1:-menu}" in
    install)      do_install      ;;
    uninstall)    do_uninstall    ;;
    toggle)       toggle_kwin     ;;
    toggle-test)  do_toggle_test  ;;
    reload-kwin)  do_reload_kwin  ;;
    verify-kwin)  do_verify_kwin  ;;
    diagnose)     do_diagnose     ;;
    status)       do_status       ;;
    menu|*)       show_menu       ;;
esac
