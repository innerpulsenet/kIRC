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
// Order matters: this is the order of the theme menu. "fluent" is first: it
// is the default for fresh installs.
var BUILTIN_IDS = ["fluent", "fluent-light", "breeze", "breeze-classic", "oxygen", "neon"]

// Older builds shipped the modern default under this id; keep it working for
// anyone with it in kirc.conf.
var ALIASES = {"breeze-dark-default": "breeze"}

// --- built-in themes (mirror of qml/themes/*.json) --------------------------
var builtins = {
    // The default: Fluent-style layered surfaces, soft shadows, rounded
    // cards, bubble chat with avatars and grouped messages. Colour tokens in
    // `surfaces` are empty, which means "fall back to the Kirigami palette at
    // the call site" — so Breeze Light, Breeze Dark and custom schemes all
    // look right. Geometry (radii, shadow) carries the Fluent character.
    "fluent": {
        "id": "fluent",
        "name": "Fluent",
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
        },
        "surfaces": {
            "surface": "",
            "surfaceAlt": "",
            "sidebarSurface": "",
            "cardBackground": "",
            "cardBorder": "",
            "cardRadius": 8,
            "cardPadding": 12,
            "rowRadius": 6,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 36,
            "accent": "",
            "accentText": "",
            "mutedText": "",
            "sectionHeader": "",
            "sectionHeaderSize": 0,
            "eventText": "",
            "eventSize": 0,
            "statusOnline": "",
            "statusAway": "",
            "statusOffline": "",
            "unreadBadge": "",
            "unreadBadgeText": "",
            "inputRadius": 4,
            "shadowOpacity": 0.18,
            "headerHeight": 48
        }
    },
    // Same Fluent geometry, tuned for light schemes (softer shadow).
    "fluent-light": {
        "id": "fluent-light",
        "name": "Fluent Light",
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
        },
        "surfaces": {
            "surface": "",
            "surfaceAlt": "",
            "sidebarSurface": "",
            "cardBackground": "",
            "cardBorder": "",
            "cardRadius": 8,
            "cardPadding": 12,
            "rowRadius": 6,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 36,
            "accent": "",
            "accentText": "",
            "mutedText": "",
            "sectionHeader": "",
            "sectionHeaderSize": 0,
            "eventText": "",
            "eventSize": 0,
            "statusOnline": "",
            "statusAway": "",
            "statusOffline": "",
            "unreadBadge": "",
            "unreadBadgeText": "",
            "inputRadius": 4,
            "shadowOpacity": 0.12,
            "headerHeight": 48
        }
    },
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
        },
        "surfaces": {
            "surface": "",
            "surfaceAlt": "",
            "sidebarSurface": "",
            "cardBackground": "",
            "cardBorder": "",
            "cardRadius": 6,
            "cardPadding": 12,
            "rowRadius": 4,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 36,
            "accent": "",
            "accentText": "",
            "mutedText": "",
            "sectionHeader": "",
            "sectionHeaderSize": 0,
            "eventText": "",
            "eventSize": 0,
            "statusOnline": "",
            "statusAway": "",
            "statusOffline": "",
            "unreadBadge": "",
            "unreadBadgeText": "",
            "inputRadius": 4,
            "shadowOpacity": 0,
            "headerHeight": 48
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
        },
        "surfaces": {
            "surface": "",
            "surfaceAlt": "",
            "sidebarSurface": "",
            "cardBackground": "",
            "cardBorder": "",
            "cardRadius": 6,
            "cardPadding": 12,
            "rowRadius": 4,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 36,
            "accent": "",
            "accentText": "",
            "mutedText": "",
            "sectionHeader": "",
            "sectionHeaderSize": 0,
            "eventText": "",
            "eventSize": 0,
            "statusOnline": "",
            "statusAway": "",
            "statusOffline": "",
            "unreadBadge": "",
            "unreadBadgeText": "",
            "inputRadius": 4,
            "shadowOpacity": 0,
            "headerHeight": 48
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
        },
        "surfaces": {
            "surface": "",
            "surfaceAlt": "",
            "sidebarSurface": "",
            "cardBackground": "",
            "cardBorder": "",
            "cardRadius": 8,
            "cardPadding": 12,
            "rowRadius": 6,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 36,
            "accent": "",
            "accentText": "",
            "mutedText": "",
            "sectionHeader": "",
            "sectionHeaderSize": 0,
            "eventText": "",
            "eventSize": 0,
            "statusOnline": "",
            "statusAway": "",
            "statusOffline": "",
            "unreadBadge": "",
            "unreadBadgeText": "",
            "inputRadius": 6,
            "shadowOpacity": 0,
            "headerHeight": 48
        }
    },
    // Fixed dark look: explicit surfaces, neon accent.
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
        },
        "surfaces": {
            "surface": "#12161b",
            "surfaceAlt": "#1a2129",
            "sidebarSurface": "#0d1116",
            "cardBackground": "#1a2129",
            "cardBorder": "#2e3d4d",
            "cardRadius": 10,
            "cardPadding": 12,
            "rowRadius": 6,
            "rowHover": "#222d38",
            "rowSelected": "#27374a",
            "rowHeight": 36,
            "accent": "#35d0ff",
            "accentText": "#0b0e11",
            "mutedText": "#8b98a5",
            "sectionHeader": "#8b98a5",
            "sectionHeaderSize": 0,
            "eventText": "#8b98a5",
            "eventSize": 0,
            "statusOnline": "#3ddc84",
            "statusAway": "#ffb020",
            "statusOffline": "#5b6b7a",
            "unreadBadge": "#35d0ff",
            "unreadBadgeText": "#0b0e11",
            "inputRadius": 6,
            "shadowOpacity": 0.35,
            "headerHeight": 48
        }
    }
}

// --- defaults for anything the JSON does not (or wrongly) specify ----------
// The default theme *is* the modern Fluent look.
var DEFAULTS = builtins["fluent"]

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
// Event rows + day separators.
//
// The bridge synthesizes join/part/quit/mode/topic lines with nick "*" (and
// server-console lines use "*" too). Those are not chat: they render as muted
// compact event rows and they always break message groups.
// ---------------------------------------------------------------------------

// True for the decorative nicks ("*" or empty) that mark an event row.
function isEventNick(nick)
{
    var s = String(nick === undefined || nick === null ? "" : nick).trim()
    return s === "" || s === "*"
}

// True for a row object (nick/timestamp/isSelf) that renders as an event row.
// Tolerates half-initialised neighbours (missing values => not an event).
function isEventRow(row)
{
    if (row === undefined || row === null) {
        return false
    }
    return isEventNick(row.nick)
}

// ---------------------------------------------------------------------------
// Message grouping.
//
// The model only exposes a preformatted local time ("HH:MM", optionally
// "HH:MM:SS"), so two messages belong to the same group when they are from the
// same person (same self/other side too) and no more than `windowMinutes`
// apart. Anything unparseable is *not* grouped — a wrong avatar is worse than
// a duplicated one. Event rows never group, with anything.
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
    if (isEventNick(a) || isEventNick(b)) {
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
// Day separators.
//
// Timestamps carry no date, so a clock running backwards (23:59 -> 00:01) is
// the only day signal. The delegate computes this once per row at settle time
// (never per frame) and renders a small centred pill above the row.
// ---------------------------------------------------------------------------

// "HH:MM" clock strings -> true when `ts` is earlier than `prevTs`, i.e. the
// day rolled over between them. Unparseable sides never open a separator.
function dayBoundaryMinutes(prevTs, ts)
{
    var t1 = parseTimestampMinutes(prevTs)
    var t2 = parseTimestampMinutes(ts)
    if (t1 < 0 || t2 < 0) {
        return false
    }
    return t2 < t1
}

// Row-object wrapper for the delegate's neighbour lookups.
function dayBoundaryRows(prev, row)
{
    if (prev === undefined || prev === null || row === undefined || row === null) {
        return false
    }
    return dayBoundaryMinutes(prev.timestamp, row.timestamp)
}

// True when no later rollover follows `row` — its day is the latest one shown,
// so the pill reads "Today", otherwise "Yesterday". (With HH:MM stamps the
// exact calendar date is unknowable; relative labels stay honest.)
function latestDayRows(row, next)
{
    if (row === undefined || row === null) {
        return true
    }
    if (next === undefined || next === null) {
        return true
    }
    return !dayBoundaryMinutes(row.timestamp, next.timestamp)
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

function copySection(section)
{
    var out = {}
    for (var k in section) { out[k] = section[k] }
    return out
}

function mergeTheme(override)
{
    var out = {}
    for (var k in DEFAULTS) {
        out[k] = isPlainObject(DEFAULTS[k]) ? copySection(DEFAULTS[k]) : DEFAULTS[k]
    }
    if (!isPlainObject(override)) {
        return out
    }
    for (var key in override) {
        var val = override[key]
        if (isPlainObject(out[key]) && isPlainObject(val)) {
            var merged = copySection(out[key])
            for (var ok in val) { merged[ok] = val[ok] }
            out[key] = merged
        } else if (!isPlainObject(out[key]) && val !== undefined && val !== null) {
            out[key] = val
        } else if (isPlainObject(out[key]) && !isPlainObject(val)) {
            // Wrong-typed section (e.g. "surfaces": "dark"): keep defaults
            // instead of crashing every binding that reads the section.
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
    var surf = out.surfaces
    surf.cardRadius = clampNumber(surf.cardRadius, 0, 64, DEFAULTS.surfaces.cardRadius)
    surf.cardPadding = clampNumber(surf.cardPadding, 0, 64, DEFAULTS.surfaces.cardPadding)
    surf.rowRadius = clampNumber(surf.rowRadius, 0, 64, DEFAULTS.surfaces.rowRadius)
    surf.rowHeight = clampNumber(surf.rowHeight, 0, 256, DEFAULTS.surfaces.rowHeight)
    surf.inputRadius = clampNumber(surf.inputRadius, 0, 64, DEFAULTS.surfaces.inputRadius)
    surf.shadowOpacity = clampNumber(surf.shadowOpacity, 0, 1, DEFAULTS.surfaces.shadowOpacity)
    surf.headerHeight = clampNumber(surf.headerHeight, 0, 512, DEFAULTS.surfaces.headerHeight)
    surf.sectionHeaderSize = clampNumber(surf.sectionHeaderSize, 0, 64, DEFAULTS.surfaces.sectionHeaderSize)
    surf.eventSize = clampNumber(surf.eventSize, 0, 64, DEFAULTS.surfaces.eventSize)
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
