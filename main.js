// ============================================================
//  main.js — KWin Script: Island Panels Maximize Toggle  v2.0
//
//  Hiding strategy: move panels to the OPPOSITE screen edge
//  (location='top') with hiding='autohide'.
//
//  Why: autohide hides panels completely off-screen. Moving them
//  to the top edge means their hover zone is at the TOP of the
//  screen — nowhere near the bottom where normal usage happens.
//  Users cannot accidentally hover the hidden panels.
//
//  This also avoids the height=1 approach which corrupted the
//  panel config by writing thickness=1 persistently.
//
//  Toggle:
//   Maximize → islands: location=top, hiding=autohide (hidden at top)
//              unified:  location=bottom, floating=false, hiding=none
//   Restore  → islands: location=bottom, floating=true, hiding=none
//              unified:  location=top, hiding=autohide (hidden at top)
// ============================================================

var ISLAND_IDS  = [@@ISLAND_IDS@@];
var UNIFIED_IDS = [@@UNIFIED_IDS@@];
var PANEL_H     = @@PANEL_HEIGHT@@;

// ─── Hide islands at top edge, show unified at bottom ─────────
var SCRIPT_TO_UNIFIED =
    'var ii=[' + ISLAND_IDS.join(',')  + '];' +
    'var ui=[' + UNIFIED_IDS.join(',') + '];' +
    'var ps=panels();' +
    'for(var i=0;i<ps.length;i++){' +
    '  var p=ps[i];' +
    '  if(ii.indexOf(p.id)>=0){' +
    '    p.location="top";' +       // move to top edge
    '    p.hiding="autohide";' +    // autohide: slides above top, hover zone at top only
    '  }' +
    '  if(ui.indexOf(p.id)>=0){' +
    '    p.location="bottom";' +    // move to bottom edge
    '    p.floating=false;' +       // classic bar, no rounding
    '    p.hiding="none";' +        // always visible
    '  }' +
    '}';

// ─── Show islands at bottom, hide unified at top edge ─────────
var SCRIPT_TO_ISLANDS =
    'var ii=[' + ISLAND_IDS.join(',')  + '];' +
    'var ui=[' + UNIFIED_IDS.join(',') + '];' +
    'var ps=panels();' +
    'for(var i=0;i<ps.length;i++){' +
    '  var p=ps[i];' +
    '  if(ii.indexOf(p.id)>=0){' +
    '    p.location="bottom";' +    // back to bottom
    '    p.floating=true;' +        // rounded floating islands
    '    p.hiding="none";' +        // always visible
    '  }' +
    '  if(ui.indexOf(p.id)>=0){' +
    '    p.location="top";' +       // park at top edge
    '    p.hiding="autohide";' +    // autohide: slides above top, unreachable from bottom
    '  }' +
    '}';

var isUnifiedMode = false;

function runPlasmaScript(js) {
    try {
        callDBus('org.kde.plasmashell', '/PlasmaShell',
                 'org.kde.PlasmaShell', 'evaluateScript',
                 js, function() {});
    } catch(e) {
        try {
            callDBus('org.kde.plasmashell', '/PlasmaShell',
                     'org.kde.PlasmaShell', 'evaluateScript', js);
        } catch(e2) {}
    }
}

function getWindows() {
    try { var w = workspace.windows;    if (w && w.length >= 0) return w; } catch(e) {}
    try { var w = workspace.windowList();               if (w) return w; } catch(e) {}
    try { var w = workspace.clientList();               if (w) return w; } catch(e) {}
    return [];
}

function windowIsMaximized(win) {
    try {
        if (!win || win.desktopWindow || win.dock || win.minimized) return false;
        if (typeof win.maximizeMode !== 'undefined') return win.maximizeMode === 3;
        if (typeof win.maximizedHorizontally !== 'undefined')
            return win.maximizedHorizontally && win.maximizedVertically;
        if (typeof win.maximized !== 'undefined') return !!win.maximized;
    } catch(e) {}
    return false;
}

function anyMaximized() {
    var wins = getWindows();
    for (var i = 0; i < wins.length; i++)
        if (windowIsMaximized(wins[i])) return true;
    return false;
}

function checkAndUpdate() {
    var maxed = anyMaximized();
    if (maxed && !isUnifiedMode) {
        isUnifiedMode = true;
        print('[island-panels] maximize → unified (islands→top/autohide)');
        runPlasmaScript(SCRIPT_TO_UNIFIED);
    } else if (!maxed && isUnifiedMode) {
        isUnifiedMode = false;
        print('[island-panels] restore → islands (unified→top/autohide)');
        runPlasmaScript(SCRIPT_TO_ISLANDS);
    }
}

try { workspace.windowMaximizeSet.connect(function() { checkAndUpdate(); }); } catch(e) {}
try { workspace.clientMaximizeSet.connect(function() { checkAndUpdate(); }); } catch(e) {}

function connectWindowSignals(win) {
    if (!win) return;
    try { win.maximizedChanged.connect(function()  { checkAndUpdate(); }); } catch(e) {}
    try { win.clientMaximizeSet.connect(function() { checkAndUpdate(); }); } catch(e) {}
}

try {
    var wins = getWindows();
    for (var i = 0; i < wins.length; i++) connectWindowSignals(wins[i]);
} catch(e) {}

try { workspace.windowAdded.connect(function(w)  { connectWindowSignals(w); checkAndUpdate(); }); } catch(e) {}
try { workspace.clientAdded.connect(function(w)  { connectWindowSignals(w); checkAndUpdate(); }); } catch(e) {}
try { workspace.windowRemoved.connect(function() { checkAndUpdate(); }); } catch(e) {}
try { workspace.clientRemoved.connect(function() { checkAndUpdate(); }); } catch(e) {}

try {
    var pollTimer = new QTimer();
    pollTimer.interval = 1000;
    pollTimer.timeout.connect(checkAndUpdate);
    pollTimer.start();
    print('[island-panels] v2.0 loaded — islands=' + ISLAND_IDS + ' unified=' + UNIFIED_IDS);
} catch(e) {
    print('[island-panels] QTimer error: ' + e);
}

try { checkAndUpdate(); } catch(e) {}
