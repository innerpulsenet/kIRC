// Theme.js — kIRC theme data + pure-JS helpers.
//
// This is a `.pragma library` JavaScript file: it has NO access to Qt globals
// (no Qt.hsla, no Qt.rgba). Anything that needs a real colour lives in
// ThemeEngine.qml, which imports this library and does the Qt-side conversion.
//
// The built-in themes below are the JS mirror of qml/themes/*.json.
// The JSON files are the canonical, user-facing schema (documented in
// qml/README.md); the C++ side reads ~/.config/kIRC/themes/*.json and pushes
// the parsed object into ThemeEngine.applyThemeJson(). QML cannot do file I/O
// itself, so the built-ins are duplicated here as JS objects.
//
// NOTE: this file is the *only* JS module shipped next to the QML (see
// EXTRA_RESOURCES in rust/build.rs), so every shared JS helper — theme maths,
// text safety and message grouping — has to live here.

.pragma library

// --- built-in theme ids -----------------------------------------------------
// Order matters: this is the order of the theme menu.
var BUILTIN_IDS = ["breeze", "breeze-classic", "oxygen", "neon"]

// Older builds shipped the modern default under this id; keep it working for
// anyone with it in kirc.conf.
var ALIASES = {"breeze-dark-default": "breeze"}

// --- built-in themes (mirror of qml/themes/*.json) --------------------------
var builtins = {
    // The default: modern bubble chat with avatars, grouped messages and
    // subtle motion. Colours come from the KDE palette, so it is correct in
    // both Breeze Light and Breeze Dark.
    "breeze": {
        "id": "breeze",
        "name": "Breeze",
        "mode": "bubble",
        "bubble": {
            "radius": 12,
            "spacing": 6,
            "groupSpacing": 2,
            "tailRadius": 5,
            "maxWidthFraction": 0.78,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 3},
        "avatar": {"enabled": true, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 140},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.70,
            "nickLightnessDark": 0.62,
            "nickLightnessLight": 0.35,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        }
    },
    // The classic IRC look: one compact line per message, no avatars.
    "breeze-classic": {
        "id": "breeze-classic",
        "name": "Breeze Classic",
        "mode": "dense",
        "bubble": {
            "radius": 8,
            "spacing": 4,
            "groupSpacing": 2,
            "tailRadius": 4,
            "maxWidthFraction": 0.78,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 120},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.70,
            "nickLightnessDark": 0.62,
            "nickLightnessLight": 0.35,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        }
    },
    "oxygen": {
        "id": "oxygen",
        "name": "Oxygen",
        "mode": "dense",
        "bubble": {
            "radius": 10,
            "spacing": 6,
            "groupSpacing": 2,
            "tailRadius": 4,
            "maxWidthFraction": 0.78,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 3},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 120},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.65,
            "nickLightnessDark": 0.68,
            "nickLightnessLight": 0.32,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        }
    },
    "neon": {
        "id": "neon",
        "name": "Neon",
        "mode": "bubble",
        "bubble": {
            "radius": 14,
            "spacing": 8,
            "groupSpacing": 3,
            "tailRadius": 5,
            "maxWidthFraction": 0.78,
            "selfColor": "#2b0f4d",
            "otherColor": "#101820"
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": true, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 160},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.70,
            "nickSatMax": 0.95,
            "nickLightnessDark": 0.70,
            "nickLightnessLight": 0.40,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        }
    }
}

// --- defaults for anything the JSON does not (or wrongly) specify ----------
// Identical to the `breeze` built-in: the default theme *is* the modern look.
var DEFAULTS = builtins["breeze"]

// Resolve a legacy/aliased theme id.
function canonicalId(id)
{
    if (typeof id === "string" && ALIASES.hasOwnProperty(id)) {
        return ALIASES[id]
    }
    return id
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

// First meaningful character of a nick, upper-cased — the letter drawn inside
// an avatar circle. Falls back to "?" for empty/decorative nicks.
function nickInitial(nick)
{
    var s = String(nick === undefined || nick === null ? "" : nick).trim()
    for (var i = 0; i < s.length; ++i) {
        var ch = s.charAt(i)
        if (/[a-z0-9]/i.test(ch)) {
            return ch.toUpperCase()
        }
    }
    return "?"
}

// ---------------------------------------------------------------------------
// Message grouping.
//
// The model only exposes a preformatted local time ("HH:MM", optionally
// "HH:MM:SS"), so two messages belong to the same group when they are from the
// same person (same self/other side too) and no more than `windowMinutes`
// apart. Anything unparseable is *not* grouped — a wrong avatar is worse than
// a duplicated one.
// ---------------------------------------------------------------------------

// "HH:MM[:SS]" -> minutes since midnight, or -1 when not understood.
function parseTimestampMinutes(ts)
{
    if (ts === undefined || ts === null) {
        return -1
    }
    var m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?/.exec(String(ts).trim())
    if (!m) {
        return -1
    }
    var h = parseInt(m[1], 10)
    var mi = parseInt(m[2], 10)
    if (isNaN(h) || isNaN(mi) || h > 23 || mi > 59) {
        return -1
    }
    return h * 60 + mi
}

// True when `nick`/`ts` continues the group started by prevNick/prevTs.
// A timestamp that goes backwards is a day rollover: never group across it.
function sameGroup(prevNick, prevTs, prevSelf, nick, ts, isSelf, windowMinutes)
{
    if (prevNick === undefined || prevNick === null) {
        return false
    }
    var a = String(prevNick).trim()
    var b = String(nick === undefined || nick === null ? "" : nick).trim()
    if (a.length === 0 || b.length === 0) {
        return false
    }
    if (a.toLowerCase() !== b.toLowerCase()) {
        return false
    }
    if (Boolean(prevSelf) !== Boolean(isSelf)) {
        return false
    }
    var t1 = parseTimestampMinutes(prevTs)
    var t2 = parseTimestampMinutes(ts)
    if (t1 < 0 || t2 < 0) {
        return false
    }
    var win = (typeof windowMinutes === "number" && windowMinutes >= 0) ? windowMinutes : 5
    var delta = t2 - t1
    return delta >= 0 && delta <= win
}

// Convenience wrapper used by MessageDelegate: a "row" is any object exposing
// nick/timestamp/isSelf.
function rowsAreGrouped(prev, row, windowMinutes)
{
    if (prev === undefined || prev === null || row === undefined || row === null) {
        return false
    }
    return sameGroup(prev.nick, prev.timestamp, prev.isSelf,
                     row.nick, row.timestamp, row.isSelf, windowMinutes)
}

// ---------------------------------------------------------------------------
// Text safety / linkification.
// QML does no network access at all: we never fetch link previews, we only
// turn already-received plain text into anchors. Always escape first so that a
// message containing "<b>" is displayed literally instead of being interpreted.
// ---------------------------------------------------------------------------
function stripIrcFormatting(s)
{
    var t = String(s === undefined || s === null ? "" : s)
    // mIRC: bold, italic, underline, strikethrough, mono, reverse, reset
    t = t.replace(/[\x02\x0f\x11\x16\x1d\x1e\x1f]/g, "")
    // colour: \x03 optionally fg[,bg]
    t = t.replace(/\x03(?:\d{1,2}(?:,\d{1,2})?)?/g, "")
    // hex colour
    t = t.replace(/\x04[0-9a-fA-F]{0,6}/g, "")
    // other C0 except tab/newline
    t = t.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "")
    return t
}

function escapeHtml(s)
{
    return stripIrcFormatting(s)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;")
}

var URL_RE = /(https?:\/\/[^\s<>"')\]]+)/g

// `cssColor` is an optional "#rrggbb" that gets baked into the anchor so the
// link follows the active theme even on widgets that do not expose a link
// colour. Passing an empty string keeps Qt's default anchor styling.
function linkify(s, cssColor)
{
    var style = cssColor ? " style=\"color:" + cssColor + "\"" : ""
    return escapeHtml(s).replace(URL_RE, "<a href=\"$1\"" + style + ">$1</a>")
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
    // Clamp the numeric knobs that drive geometry so a bad theme file cannot
    // produce an unreadable (or unusable) chat view.
    out.bubble.maxWidthFraction = clampNumber(out.bubble.maxWidthFraction, 0.3, 1.0, DEFAULTS.bubble.maxWidthFraction)
    out.bubble.radius = clampNumber(out.bubble.radius, 0, 64, DEFAULTS.bubble.radius)
    out.bubble.tailRadius = clampNumber(out.bubble.tailRadius, 0, 64, DEFAULTS.bubble.tailRadius)
    out.bubble.spacing = clampNumber(out.bubble.spacing, 0, 64, DEFAULTS.bubble.spacing)
    out.bubble.groupSpacing = clampNumber(out.bubble.groupSpacing, 0, 64, DEFAULTS.bubble.groupSpacing)
    out.dense.lineSpacing = clampNumber(out.dense.lineSpacing, 0, 64, DEFAULTS.dense.lineSpacing)
    out.avatar.size = clampNumber(out.avatar.size, 0, 256, DEFAULTS.avatar.size)
    out.grouping.windowMinutes = clampNumber(out.grouping.windowMinutes, 0, 1440, DEFAULTS.grouping.windowMinutes)
    out.motion.duration = clampNumber(out.motion.duration, 0, 1000, DEFAULTS.motion.duration)
    out.sidebar.width = clampNumber(out.sidebar.width, 0, 4096, DEFAULTS.sidebar.width)
    return out
}

function clampNumber(value, lo, hi, fallback)
{
    var v = Number(value)
    if (!isFinite(v)) {
        return fallback
    }
    return Math.min(hi, Math.max(lo, v))
}

function cloneTheme(theme)
{
    return mergeTheme(theme)
}
