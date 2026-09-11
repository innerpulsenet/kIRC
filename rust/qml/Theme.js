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
// TERMINAL LOOK (schema version 3): bubbles are cancelled. Every built-in is
// `mode: "dense"` — monospace, one line per message, flat surfaces, no
// avatars, no grouping pills. The retired bubble/glass themes (fluent,
// fluent-light, oxygen, neon, breeze-classic) live on only as *aliases* to the
// TUI default, so a stale config id can never leave the window unstyled; the
// C++ migration (`ThemeSchemaVersion` 3, see cpp/kircconfig.cpp) rewrites them
// on disk.
//
// NOTE: this file is the *only* JS module shipped next to the QML (see
// EXTRA_RESOURCES in rust/build.rs), so every shared JS helper — theme maths,
// text safety and message grouping — has to live here.

.pragma library

// --- built-in theme ids -----------------------------------------------------
// Order matters: this is the order of the theme menu. "tui" is first: it is
// the default for fresh installs and the migration target for every config
// written before schema version 3.
var BUILTIN_IDS = ["tui", "phosphor", "amber", "ice", "breeze"]

// Older builds shipped other default ids; keep them working. The retired
// bubble/glass ids resolve to the TUI default so applying one can never leave
// the UI without a theme (the C++ migration normally rewrites them first).
var ALIASES = {
    "breeze-dark-default": "breeze",
    "fluent": "tui",
    "fluent-light": "tui",
    "oxygen": "tui",
    "neon": "tui",
    "breeze-classic": "tui"
}

// --- built-in themes (mirror of qml/themes/*.json) --------------------------
// All five are dense terminal palettes: monospace, flat, one line per message.
//  * tui       neutral terminal — near-black log, grey text, cyan accent
//  * phosphor  green on black (P1 tube)
//  * amber     amber on black (classic CRT)
//  * ice       light text on dark blue (C64-ish)
//  * breeze    dense geometry, Kirigami palette colours ("follows the desktop")
// Colour tokens that are "" mean "fall back to the Kirigami palette at the
// call site"; the geometry tokens carry the (flat) character.
var builtins = {
    "tui": {
        "id": "tui",
        "name": "TUI",
        "mode": "dense",
        "bubble": {
            "radius": 0,
            "spacing": 0,
            "groupSpacing": 0,
            "tailRadius": 0,
            "maxWidthFraction": 1.0,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 90},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.50,
            "nickSatMax": 0.80,
            "nickLightnessDark": 0.70,
            "nickLightnessLight": 0.34,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#0b0d0f",
            "surfaceAlt": "#101417",
            "sidebarSurface": "#0e1215",
            "cardBackground": "#101417",
            "cardBorder": "#262e34",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#171d22",
            "rowSelected": "#1e272e",
            "rowHeight": 24,
            "accent": "#4cc9dd",
            "accentText": "#0b0d0f",
            "mutedText": "#7c858c",
            "sectionHeader": "#7c858c",
            "sectionHeaderSize": 0,
            "eventText": "#7c858c",
            "eventSize": 0,
            "statusOnline": "#63c47a",
            "statusAway": "#d8b25e",
            "statusOffline": "#6d757b",
            "unreadBadge": "#4cc9dd",
            "unreadBadgeText": "#0b0d0f",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#2b3238",
            "fgPrimary": "#c9ced3",
            "fgDim": "#7c858c",
            "fgAccent": "#4cc9dd",
            "fgWarn": "#ff6b5f",
            "bgPanel": "#101417",
            "bgLog": "#0b0d0f",
            "bgInput": "#0e1215"
        }
    },
    // Green on black — a P1 phosphor tube.
    "phosphor": {
        "id": "phosphor",
        "name": "Phosphor",
        "mode": "dense",
        "bubble": {
            "radius": 0,
            "spacing": 0,
            "groupSpacing": 0,
            "tailRadius": 0,
            "maxWidthFraction": 1.0,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 90},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.45,
            "nickSatMax": 0.75,
            "nickLightnessDark": 0.72,
            "nickLightnessLight": 0.30,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#030803",
            "surfaceAlt": "#061006",
            "sidebarSurface": "#040b04",
            "cardBackground": "#061006",
            "cardBorder": "#124020",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#07170c",
            "rowSelected": "#0b2413",
            "rowHeight": 24,
            "accent": "#3fe05f",
            "accentText": "#030803",
            "mutedText": "#1f9e46",
            "sectionHeader": "#1f9e46",
            "sectionHeaderSize": 0,
            "eventText": "#1f9e46",
            "eventSize": 0,
            "statusOnline": "#3fe05f",
            "statusAway": "#cfc25a",
            "statusOffline": "#16512d",
            "unreadBadge": "#3fe05f",
            "unreadBadgeText": "#030803",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#14421f",
            "fgPrimary": "#3fe05f",
            "fgDim": "#1f9e46",
            "fgAccent": "#a8ffb8",
            "fgWarn": "#ff6359",
            "bgPanel": "#061006",
            "bgLog": "#030803",
            "bgInput": "#040b04"
        }
    },
    // Amber on black — the classic CRT terminal.
    "amber": {
        "id": "amber",
        "name": "Amber",
        "mode": "dense",
        "bubble": {
            "radius": 0,
            "spacing": 0,
            "groupSpacing": 0,
            "tailRadius": 0,
            "maxWidthFraction": 1.0,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 90},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.50,
            "nickSatMax": 0.80,
            "nickLightnessDark": 0.72,
            "nickLightnessLight": 0.32,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#0c0700",
            "surfaceAlt": "#120c02",
            "sidebarSurface": "#0f0a02",
            "cardBackground": "#120c02",
            "cardBorder": "#3c2a08",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#1c1304",
            "rowSelected": "#291c06",
            "rowHeight": 24,
            "accent": "#ffb000",
            "accentText": "#0c0700",
            "mutedText": "#9a6a1a",
            "sectionHeader": "#9a6a1a",
            "sectionHeaderSize": 0,
            "eventText": "#9a6a1a",
            "eventSize": 0,
            "statusOnline": "#b8cf4e",
            "statusAway": "#d9a12b",
            "statusOffline": "#5c4a24",
            "unreadBadge": "#ffb000",
            "unreadBadgeText": "#0c0700",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#402d0a",
            "fgPrimary": "#ffb000",
            "fgDim": "#9a6a1a",
            "fgAccent": "#ffd27a",
            "fgWarn": "#ff5f52",
            "bgPanel": "#120c02",
            "bgLog": "#0c0700",
            "bgInput": "#0f0a02"
        }
    },
    // Light text on dark blue — C64-ish.
    "ice": {
        "id": "ice",
        "name": "Ice",
        "mode": "dense",
        "bubble": {
            "radius": 0,
            "spacing": 0,
            "groupSpacing": 0,
            "tailRadius": 0,
            "maxWidthFraction": 1.0,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 90},
        "sidebar": {"width": 0},
        "fonts": {"messageSize": 0, "timestampSize": 0, "nickSize": 0},
        "colors": {
            "nickSatMin": 0.45,
            "nickSatMax": 0.75,
            "nickLightnessDark": 0.76,
            "nickLightnessLight": 0.32,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#101134",
            "surfaceAlt": "#151645",
            "sidebarSurface": "#121339",
            "cardBackground": "#151645",
            "cardBorder": "#34377a",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#1a1b4e",
            "rowSelected": "#232565",
            "rowHeight": 24,
            "accent": "#67b6bd",
            "accentText": "#101134",
            "mutedText": "#8ea0d8",
            "sectionHeader": "#9fb0e8",
            "sectionHeaderSize": 0,
            "eventText": "#8ea0d8",
            "eventSize": 0,
            "statusOnline": "#94e089",
            "statusAway": "#bfce72",
            "statusOffline": "#5a5f9e",
            "unreadBadge": "#67b6bd",
            "unreadBadgeText": "#101134",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#2c2f6b",
            "fgPrimary": "#d7e2ff",
            "fgDim": "#8ea0d8",
            "fgAccent": "#67b6bd",
            "fgWarn": "#e08a80",
            "bgPanel": "#151645",
            "bgLog": "#101134",
            "bgInput": "#121339"
        }
    },
    // Dense geometry, Kirigami palette colours: the same console layout as the
    // others, but every colour is "" = "use the desktop scheme", so it matches
    // Breeze Light, Breeze Dark and any custom colour scheme.
    "breeze": {
        "id": "breeze",
        "name": "Breeze",
        "mode": "dense",
        "bubble": {
            "radius": 0,
            "spacing": 0,
            "groupSpacing": 0,
            "tailRadius": 0,
            "maxWidthFraction": 1.0,
            "selfColor": "",
            "otherColor": ""
        },
        "dense": {"lineSpacing": 2},
        "avatar": {"enabled": false, "size": 0},
        "grouping": {"enabled": true, "windowMinutes": 5},
        "motion": {"enabled": true, "duration": 90},
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
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "",
            "rowSelected": "",
            "rowHeight": 26,
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
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 60,
            "nickColumn": 9,
            "ruleColor": "",
            "fgPrimary": "",
            "fgDim": "",
            "fgAccent": "",
            "fgWarn": "",
            "bgPanel": "",
            "bgLog": "",
            "bgInput": ""
        }
    }
}

// --- defaults for anything the JSON does not (or wrongly) specify ----------
// The default theme *is* the terminal look.
var DEFAULTS = builtins["tui"]

// Resolve a legacy/aliased theme id.
function canonicalId(id)
{
    if (typeof id === "string" && ALIASES.hasOwnProperty(id)) {
        return ALIASES[id]
    }
    return id
}

// True for ids that used to ship as built-in bubble/glass themes (schema < 3).
// The C++ migration rewrites these to "tui"; ThemeEngine keeps the list too so
// a picker or the harness can reason about them.
var RETIRED_IDS = ["breeze-classic", "oxygen", "neon", "fluent", "fluent-light"]

function isRetiredId(id)
{
    if (typeof id !== "string") {
        return false
    }
    return RETIRED_IDS.indexOf(id.toLowerCase()) >= 0
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
// ones; themes override it (the terminal palettes are tuned brighter).
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

// First meaningful character of a nick, upper-cased. Kept for the person
// panel / channel tiles that still draw a glyph.
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

// Pad `nick` to `width` characters with spaces (dense IRC nick column). A nick
// that is already at least `width` characters long is returned unchanged —
// truncating a nick would misattribute messages.
function padNick(nick, width)
{
    var n = String(nick === undefined || nick === null ? "" : nick)
    var w = Number(width)
    if (!isFinite(w) || w <= 0 || n.length >= w) {
        return n
    }
    var pad = ""
    while (pad.length < w - n.length) {
        pad += " "
    }
    return n + pad
}

// ---------------------------------------------------------------------------
// Event rows + day separators.
//
// The bridge synthesizes join/part/quit/mode/topic lines with nick "*" (and
// server-console lines use "*" too). Those are not chat: they render as muted
// compact event rows (classic `* nick did a thing`).
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
// Message spanning (kept for compatibility).
//
// Older builds collapsed a repeated sender into one visual group (a messenger
// idea). Dense IRC rendering shows one line per message, so nothing decides to
// "continue" a previous row any more — but the helpers stay: MessageDelegate
// and the harnesses call them, and they are harmless.
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
// A timestamp that goes backwards is a day rollover: never continue across it.
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

// Convenience wrapper used by callers: a "row" is any object exposing
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
// the only day signal.
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

// Row-object wrapper for neighbour lookups.
function dayBoundaryRows(prev, row)
{
    if (prev === undefined || prev === null || row === undefined || row === null) {
        return false
    }
    return dayBoundaryMinutes(prev.timestamp, row.timestamp)
}

// True when no later rollover follows `row` — its day is the latest one shown.
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
// wrong-typed sections fall back instead of crashing the UI. A theme written
// against the old bubble schema (radius/avatar/grouping keys) therefore still
// loads — it simply inherits the dense geometry.
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
    // Mode is dense, always: bubbles are gone, so an old theme file that says
    // "mode": "bubble" (or anything else) still renders the console layout.
    out.mode = "dense"
    // Clamp the numeric knobs that drive geometry so a bad theme file cannot
    // produce an unreadable (or unusable) chat view. The old bubble keys are
    // still tolerated (and still clamped) because old JSON in
    // ~/.config/kIRC/themes/ must never break loading.
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
    var term = out.terminal
    term.gutterWidth = clampNumber(term.gutterWidth, 0, 512, DEFAULTS.terminal.gutterWidth)
    term.nickColumn = clampNumber(term.nickColumn, 0, 64, DEFAULTS.terminal.nickColumn)
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
