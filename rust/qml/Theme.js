// Theme.js — kIRC theme data + pure-JS helpers.
//
// This is a `.pragma library` JavaScript file: it has NO access to Qt globals
// (no Qt.hsla, no Qt.rgba). Anything that needs a real colour lives in
// ThemeEngine.qml, which imports this library and does the Qt-side conversion.
//
// The three built-in themes below are the JS mirror of qml/themes/*.json.
// The JSON files are the canonical, user-facing schema (documented in
// qml/README.md); the C++ side reads ~/.config/kIRC/themes/*.json and pushes
// the parsed object into ThemeEngine.applyThemeJson(). QML cannot do file I/O
// itself, so the built-ins are duplicated here as JS objects.

.pragma library

// --- built-in theme ids -----------------------------------------------------
var BUILTIN_IDS = ["breeze-dark-default", "oxygen", "neon"]

// --- built-in themes (mirror of qml/themes/*.json) --------------------------
var builtins = {
    "breeze-dark-default": {
        "id": "breeze-dark-default",
        "name": "Breeze Dark",
        "mode": "dense",
        "bubble": {"radius": 8, "spacing": 4, "selfColor": "", "otherColor": ""},
        "dense": {"lineSpacing": 2},
        "fonts": {"messageSize": 0, "timestampSize": 0},
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.70,
            "nickLightnessDark": 0.62,
            "nickLightnessLight": 0.35,
            "linkify": true,
            "highlightIsBold": true
        }
    },
    "oxygen": {
        "id": "oxygen",
        "name": "Oxygen",
        "mode": "dense",
        "bubble": {"radius": 10, "spacing": 6, "selfColor": "", "otherColor": ""},
        "dense": {"lineSpacing": 3},
        "fonts": {"messageSize": 0, "timestampSize": 0},
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.65,
            "nickLightnessDark": 0.68,
            "nickLightnessLight": 0.32,
            "linkify": true,
            "highlightIsBold": true
        }
    },
    "neon": {
        "id": "neon",
        "name": "Neon",
        "mode": "bubble",
        "bubble": {"radius": 12, "spacing": 8, "selfColor": "#2b0f4d", "otherColor": "#101820"},
        "dense": {"lineSpacing": 2},
        "fonts": {"messageSize": 0, "timestampSize": 0},
        "colors": {
            "nickSatMin": 0.70,
            "nickSatMax": 0.95,
            "nickLightnessDark": 0.70,
            "nickLightnessLight": 0.40,
            "linkify": true,
            "highlightIsBold": true
        }
    }
}

// --- defaults for anything the JSON does not (or wrongly) specify ----------
var DEFAULTS = {
    "id": "breeze-dark-default",
    "name": "Breeze Dark",
    "mode": "dense",
    "bubble": {"radius": 8, "spacing": 4, "selfColor": "", "otherColor": ""},
    "dense": {"lineSpacing": 2},
    "fonts": {"messageSize": 0, "timestampSize": 0},
    "colors": {
        "nickSatMin": 0.55,
        "nickSatMax": 0.70,
        "nickLightnessDark": 0.62,
        "nickLightnessLight": 0.35,
        "linkify": true,
        "highlightIsBold": true
    }
}

// ---------------------------------------------------------------------------
// djb2 string hash (positive 31-bit). Deterministic, so a nick keeps its
// colour across restarts and across channel switches.
// ---------------------------------------------------------------------------
function djb2(str)
{
    var h = 5381
    var s = String(str === undefined || str === null ? "" : str).toLowerCase()
    for (var i = 0; i < s.length; ++i) {
        h = (((h << 5) + h) + s.charCodeAt(i)) | 0
    }
    return h & 0x7fffffff
}

function hueForNick(nick)
{
    return djb2(nick) % 360
}

// Deterministic saturation inside [minSat, maxSat] so nicks that land on
// nearby hues still stay visually distinct.
function saturationForNick(nick, minSat, maxSat)
{
    var t = (djb2(String(nick) + "#sat") % 1000) / 1000.0
    var lo = (typeof minSat === "number") ? minSat : 0.55
    var hi = (typeof maxSat === "number") ? maxSat : 0.70
    if (hi < lo) { var tmp = hi; hi = lo; lo = tmp }
    return lo + (hi - lo) * t
}

// Returns { hue: 0..1, sat: 0..1, light: 0..1 } — Qt.hsla() arguments.
// The spec's baseline lightness is 45% on dark backgrounds and 35% on light
// ones; themes override it (breeze/oxygen are tuned brighter for readability).
function nickColorParams(nick, dark, theme)
{
    var c = (theme && theme.colors) ? theme.colors : DEFAULTS.colors
    var hue = hueForNick(nick) / 360.0
    var sat = saturationForNick(nick, c.nickSatMin, c.nickSatMax)
    var light
    if (dark) {
        light = (typeof c.nickLightnessDark === "number") ? c.nickLightnessDark : 0.45
    } else {
        light = (typeof c.nickLightnessLight === "number") ? c.nickLightnessLight : 0.35
    }
    return {"hue": hue, "sat": sat, "light": light}
}

// ---------------------------------------------------------------------------
// Text safety / linkification.
// QML does no network access at all: we never fetch link previews, we only
// turn already-received plain text into anchors. Always escape first so that a
// message containing "<b>" is displayed literally instead of being interpreted.
// ---------------------------------------------------------------------------
function escapeHtml(s)
{
    return String(s === undefined || s === null ? "" : s)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;")
}

var URL_RE = /(https?:\/\/[^\s<>"')\]]+)/g

function linkify(s)
{
    return escapeHtml(s).replace(URL_RE, "<a href=\"$1\">$1</a>")
}

// ---------------------------------------------------------------------------
// Deep-ish merge of a user theme over DEFAULTS.
// Unknown keys are preserved (forward compatible), missing keys get defaults,
// wrong-typed sections fall back instead of crashing the UI.
// ---------------------------------------------------------------------------
function isPlainObject(v)
{
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

function mergeTheme(override)
{
    var out = {}
    for (var k in DEFAULTS) {
        out[k] = DEFAULTS[k]
    }
    if (!isPlainObject(override)) {
        return out
    }
    for (var key in override) {
        var val = override[key]
        if (isPlainObject(DEFAULTS[key]) && isPlainObject(val)) {
            var merged = {}
            for (var dk in DEFAULTS[key]) { merged[dk] = DEFAULTS[key][dk] }
            for (var ok in val) { merged[ok] = val[ok] }
            out[key] = merged
        } else if (val !== undefined && val !== null) {
            out[key] = val
        }
    }
    // Coerce mode to the two supported values.
    if (out.mode !== "dense" && out.mode !== "bubble") {
        out.mode = DEFAULTS.mode
    }
    return out
}

function cloneTheme(theme)
{
    return mergeTheme(theme)
}
