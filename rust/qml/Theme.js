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
// itself, so the built-ins are duplicated here as JS objects. The two copies
// are byte-for-byte equivalent per token — `qml-tests/check-theme-tokens.py`
// fails the build on any drift.
//
// TERMINAL LOOK (schema version 4): bubbles are cancelled and every built-in
// is `mode: "dense"` — monospace, one line per message, flat surfaces, no
// avatars, no grouping pills. The retired bubble/glass themes (fluent,
// fluent-light, oxygen, neon, breeze-classic) live on only as *aliases* to the
// TUI default, so a stale config id can never leave the window unstyled; the
// C++ migration (`ThemeSchemaVersion`, see cpp/kircconfig.cpp) rewrites them
// on disk.
//
// Schema 4 added the per-kind message tokens (fgEvent / fgMessage / fgPrivate
// / fgNotice / fgAction / fgHighlight / fgSelf) so the console log can tell
// system lines, channel chat, queries, NOTICEs, /me actions, failures and
// highlight mentions apart by colour. EVERY theme defines EVERY token — a
// missing token is a silent fallback and an extra one is a typo that never
// applies; the checker in qml-tests/ enforces the exact token set.
//
// NOTE: this file is the *only* JS module shipped next to the QML (see
// EXTRA_RESOURCES in rust/build.rs), so every shared JS helper — theme maths,
// text safety and message grouping — has to live here.

.pragma library

// --- built-in theme ids -----------------------------------------------------
// Order matters: this is the order of the theme menu. "tui" is first: it is
// the default for fresh installs and the migration target for every config
// written before schema version 3. The retro/BBS palettes follow the neutral
// set and exist to be *different rooms of the same museum*, not tints of one
// another (see the palette notes above each theme).
var BUILTIN_IDS = ["tui", "phosphor", "amber", "ice", "breeze",
                   "bbs", "c64", "vt", "ega", "synthwave", "ai-slop"]

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
// All eleven are dense terminal palettes: monospace, flat, one line per message.
//  * tui        neutral terminal — near-black log, grey text, cyan accent
//  * phosphor   green on black (P1 tube)
//  * amber      amber on black (classic CRT)
//  * ice        light text on dark blue (cold blue)
//  * breeze     dense geometry, Kirigami palette colours ("follows the desktop")
//  * bbs        ANSI/BBS door colours on black (dial-up era)
//  * c64        Commodore 64 light-blue on dark blue
//  * vt         DEC VT-style yellow-green phosphor
//  * ega        EGA/DOS 16-colour on black
//  * synthwave  neon pink/cyan on deep purple
//  * ai-slop    self-aware neon violet — the palette an LLM ships when asked
//               to "make it pop", executed well enough to actually use
// Colour tokens that are "" mean "fall back to the Kirigami palette at the
// call site"; the geometry tokens carry the (flat) character.
var builtins = {
    // Neutral terminal — near-black log, grey text, cyan accent.
    "tui": {
        "id": "tui",
        "name": "TUI",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.5,
            "nickSatMax": 0.8,
            "nickLightnessDark": 0.7,
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
            "bgInput": "#0e1215",
            "fgEvent": "#7c858c",
            "fgMessage": "#c9ced3",
            "fgPrivate": "#e0cfae",
            "fgNotice": "#7fd8e6",
            "fgAction": "#c3a8ea",
            "fgHighlight": "#f0f6fa",
            "fgSelf": "#e4ebf0"
        }
    },
    // Green on black — a P1 phosphor tube.
    "phosphor": {
        "id": "phosphor",
        "name": "Phosphor",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.45,
            "nickSatMax": 0.75,
            "nickLightnessDark": 0.72,
            "nickLightnessLight": 0.3,
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
            "bgInput": "#040b04",
            "fgEvent": "#1f9e46",
            "fgMessage": "#3fe05f",
            "fgPrivate": "#cdee4c",
            "fgNotice": "#6cf0d0",
            "fgAction": "#b49cff",
            "fgHighlight": "#d8ffe8",
            "fgSelf": "#9fffbe"
        }
    },
    // Amber on black — the classic CRT terminal.
    "amber": {
        "id": "amber",
        "name": "Amber",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.5,
            "nickSatMax": 0.8,
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
            "fgDim": "#a87a20",
            "fgAccent": "#ffd27a",
            "fgWarn": "#ff5f52",
            "bgPanel": "#120c02",
            "bgLog": "#0c0700",
            "bgInput": "#0f0a02",
            "fgEvent": "#a87a20",
            "fgMessage": "#ffb000",
            "fgPrivate": "#ffd85e",
            "fgNotice": "#ffcf9a",
            "fgAction": "#e88f2a",
            "fgHighlight": "#fff0cc",
            "fgSelf": "#ffcf7a"
        }
    },
    // Light text on dark blue — cold Warp-era blue.
    "ice": {
        "id": "ice",
        "name": "Ice",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
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
            "bgInput": "#121339",
            "fgEvent": "#8ea0d8",
            "fgMessage": "#d7e2ff",
            "fgPrivate": "#ecc9a0",
            "fgNotice": "#8ff0e8",
            "fgAction": "#b8a0ff",
            "fgHighlight": "#ffffff",
            "fgSelf": "#eaf3ff"
        }
    },
    // Dense geometry, Kirigami palette colours: the same console layout
    // as the others, but every colour is "" = "use the desktop scheme", so it
    // matches Breeze Light, Breeze Dark and any custom colour scheme.
    "breeze": {
        "id": "breeze",
        "name": "Breeze",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.7,
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
            "bgInput": "",
            "fgEvent": "",
            "fgMessage": "",
            "fgPrivate": "",
            "fgNotice": "",
            "fgAction": "",
            "fgHighlight": "",
            "fgSelf": ""
        }
    },
    // ANSI/BBS door colours on black — dial-up era cyan and yellow.
    "bbs": {
        "id": "bbs",
        "name": "BBS",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.85,
            "nickLightnessDark": 0.68,
            "nickLightnessLight": 0.34,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#000000",
            "surfaceAlt": "#0a0a0a",
            "sidebarSurface": "#050505",
            "cardBackground": "#0a0a0a",
            "cardBorder": "#2a2a2a",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#141414",
            "rowSelected": "#1e1e1e",
            "rowHeight": 24,
            "accent": "#00e0e0",
            "accentText": "#000000",
            "mutedText": "#8a8a8a",
            "sectionHeader": "#4fd06a",
            "sectionHeaderSize": 0,
            "eventText": "#4fd06a",
            "eventSize": 0,
            "statusOnline": "#55ff55",
            "statusAway": "#ffff55",
            "statusOffline": "#5c5c5c",
            "unreadBadge": "#00e0e0",
            "unreadBadgeText": "#000000",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#303030",
            "fgPrimary": "#c8c8c8",
            "fgDim": "#8a8a8a",
            "fgAccent": "#00e0e0",
            "fgWarn": "#ff5555",
            "bgPanel": "#101010",
            "bgLog": "#000000",
            "bgInput": "#000000",
            "fgEvent": "#4fd06a",
            "fgMessage": "#c8c8c8",
            "fgPrivate": "#ffe066",
            "fgNotice": "#66ffff",
            "fgAction": "#ff8ae8",
            "fgHighlight": "#ffffff",
            "fgSelf": "#e0e0e0"
        }
    },
    // Commodore 64: light blue on dark blue — the breadbin screen.
    "c64": {
        "id": "c64",
        "name": "Commodore 64",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.35,
            "nickSatMax": 0.6,
            "nickLightnessDark": 0.78,
            "nickLightnessLight": 0.34,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#2c2c9e",
            "surfaceAlt": "#26268c",
            "sidebarSurface": "#26268c",
            "cardBackground": "#26268c",
            "cardBorder": "#5f5fc8",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#3535ac",
            "rowSelected": "#4040c4",
            "rowHeight": 24,
            "accent": "#8ce89a",
            "accentText": "#2c2c9e",
            "mutedText": "#a8a8ff",
            "sectionHeader": "#8ce89a",
            "sectionHeaderSize": 0,
            "eventText": "#a8a8ff",
            "eventSize": 0,
            "statusOnline": "#8ce89a",
            "statusAway": "#ffe97a",
            "statusOffline": "#7a7ad0",
            "unreadBadge": "#ffe97a",
            "unreadBadgeText": "#2c2c9e",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#5f5fc8",
            "fgPrimary": "#d0d0ff",
            "fgDim": "#a8a8ff",
            "fgAccent": "#8ce89a",
            "fgWarn": "#ff8a8a",
            "bgPanel": "#26268c",
            "bgLog": "#2c2c9e",
            "bgInput": "#2c2c9e",
            "fgEvent": "#a8a8ff",
            "fgMessage": "#d0d0ff",
            "fgPrivate": "#ffe97a",
            "fgNotice": "#7ae8dc",
            "fgAction": "#ff9c5c",
            "fgHighlight": "#ffffff",
            "fgSelf": "#b8e8ff"
        }
    },
    // DEC VT-style phosphor: yellow-green P3 tube, bright core.
    "vt": {
        "id": "vt",
        "name": "VT Phosphor",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.45,
            "nickSatMax": 0.75,
            "nickLightnessDark": 0.72,
            "nickLightnessLight": 0.3,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#050700",
            "surfaceAlt": "#0a0d02",
            "sidebarSurface": "#080b02",
            "cardBackground": "#0a0d02",
            "cardBorder": "#2f3f14",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#121a05",
            "rowSelected": "#1c2608",
            "rowHeight": 24,
            "accent": "#eaffb0",
            "accentText": "#050700",
            "mutedText": "#7fae2f",
            "sectionHeader": "#7fae2f",
            "sectionHeaderSize": 0,
            "eventText": "#7fae2f",
            "eventSize": 0,
            "statusOnline": "#b6ff3e",
            "statusAway": "#ffef9a",
            "statusOffline": "#3f5a18",
            "unreadBadge": "#b6ff3e",
            "unreadBadgeText": "#050700",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#2f3f14",
            "fgPrimary": "#b6ff3e",
            "fgDim": "#7fae2f",
            "fgAccent": "#eaffb0",
            "fgWarn": "#ff6b52",
            "bgPanel": "#0a0d02",
            "bgLog": "#050700",
            "bgInput": "#080b02",
            "fgEvent": "#7fae2f",
            "fgMessage": "#b6ff3e",
            "fgPrivate": "#ffef9a",
            "fgNotice": "#6cf0d0",
            "fgAction": "#b49cff",
            "fgHighlight": "#f2ffe0",
            "fgSelf": "#d6ff9a"
        }
    },
    // EGA/DOS 16-colour: grey text, bright ANSI 8 on black.
    "ega": {
        "id": "ega",
        "name": "EGA",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.85,
            "nickLightnessDark": 0.7,
            "nickLightnessLight": 0.34,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#000000",
            "surfaceAlt": "#0000a8",
            "sidebarSurface": "#0000a8",
            "cardBackground": "#000000",
            "cardBorder": "#5555ff",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#0a0a4a",
            "rowSelected": "#0000c8",
            "rowHeight": 24,
            "accent": "#7a7aff",
            "accentText": "#000000",
            "mutedText": "#9a9a9a",
            "sectionHeader": "#00a8a8",
            "sectionHeaderSize": 0,
            "eventText": "#00a8a8",
            "eventSize": 0,
            "statusOnline": "#55ff55",
            "statusAway": "#ffff55",
            "statusOffline": "#555555",
            "unreadBadge": "#ffff55",
            "unreadBadgeText": "#000000",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#303030",
            "fgPrimary": "#b0b0b0",
            "fgDim": "#9a9a9a",
            "fgAccent": "#7a7aff",
            "fgWarn": "#ff5555",
            "bgPanel": "#0000a8",
            "bgLog": "#000000",
            "bgInput": "#000000",
            "fgEvent": "#00a8a8",
            "fgMessage": "#b0b0b0",
            "fgPrivate": "#ffff55",
            "fgNotice": "#55ffff",
            "fgAction": "#ff55ff",
            "fgHighlight": "#ffffff",
            "fgSelf": "#e8e8e8"
        }
    },
    // Synthwave/neon: hot pink and electric cyan on deep purple.
    "synthwave": {
        "id": "synthwave",
        "name": "Synthwave",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.8,
            "nickLightnessDark": 0.74,
            "nickLightnessLight": 0.34,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": ""
        },
        "surfaces": {
            "surface": "#170b2f",
            "surfaceAlt": "#220f3f",
            "sidebarSurface": "#1c0d38",
            "cardBackground": "#220f3f",
            "cardBorder": "#4a2a7a",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#2a1450",
            "rowSelected": "#351a63",
            "rowHeight": 24,
            "accent": "#ff4fd8",
            "accentText": "#170b2f",
            "mutedText": "#9d8bd0",
            "sectionHeader": "#7df9ff",
            "sectionHeaderSize": 0,
            "eventText": "#9d8bd0",
            "eventSize": 0,
            "statusOnline": "#7bffb2",
            "statusAway": "#ffd166",
            "statusOffline": "#6a4fa8",
            "unreadBadge": "#ff4fd8",
            "unreadBadgeText": "#170b2f",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#4a2a7a",
            "fgPrimary": "#ece5ff",
            "fgDim": "#9d8bd0",
            "fgAccent": "#ff4fd8",
            "fgWarn": "#ff5f7a",
            "bgPanel": "#220f3f",
            "bgLog": "#170b2f",
            "bgInput": "#1c0d38",
            "fgEvent": "#9d8bd0",
            "fgMessage": "#ded1ff",
            "fgPrivate": "#ffb86c",
            "fgNotice": "#7df9ff",
            "fgAction": "#ff6ec7",
            "fgHighlight": "#ffe9fb",
            "fgSelf": "#d8ccff"
        }
    },
    // AI Slop: self-aware neon violet — the palette an LLM ships when asked to
    // "make it pop". Deep indigo field, lavender-white text, electric-violet
    // accent, neon magenta for actions and the unread badge, neon cyan / mint
    // for private and notice kinds, hot pink-red for warnings. Geometry is the
    // TUI console's (bubble zeros, no avatars) — this one is palette-led.
    "ai-slop": {
        "id": "ai-slop",
        "name": "AI Slop",
        "schema": 4,
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
        "dense": { "lineSpacing": 2 },
        "avatar": { "enabled": false, "size": 0 },
        "grouping": { "enabled": true, "windowMinutes": 5 },
        "motion": { "enabled": true, "duration": 90 },
        "sidebar": { "width": 0 },
        "fonts": { "messageSize": 0, "timestampSize": 0, "nickSize": 0 },
        "colors": {
            "nickSatMin": 0.55,
            "nickSatMax": 0.95,
            "nickLightnessDark": 0.78,
            "nickLightnessLight": 0.42,
            "linkify": true,
            "highlightIsBold": true,
            "linkColor": "#8ff4ff"
        },
        "surfaces": {
            "surface": "#140e26",
            "surfaceAlt": "#1b1338",
            "sidebarSurface": "#1b1338",
            "cardBackground": "#221847",
            "cardBorder": "#3b2a6b",
            "cardRadius": 0,
            "cardPadding": 8,
            "rowRadius": 0,
            "rowHover": "#241a4d",
            "rowSelected": "#2f2263",
            "rowHeight": 24,
            "accent": "#a86cff",
            "accentText": "#140e26",
            "mutedText": "#9d8ad0",
            "sectionHeader": "#c9b6ff",
            "sectionHeaderSize": 0,
            "eventText": "#9d8ad0",
            "eventSize": 0,
            "statusOnline": "#7dffc4",
            "statusAway": "#ffd166",
            "statusOffline": "#6d55a8",
            "unreadBadge": "#ff5cf0",
            "unreadBadgeText": "#140e26",
            "inputRadius": 0,
            "shadowOpacity": 0,
            "headerHeight": 40
        },
        "terminal": {
            "fontFamily": "monospace",
            "gutterWidth": 64,
            "nickColumn": 9,
            "ruleColor": "#3b2a6b",
            "fgPrimary": "#e9e2ff",
            "fgDim": "#9d8ad0",
            "fgAccent": "#a86cff",
            "fgWarn": "#ff4d6d",
            "bgPanel": "#1b1338",
            "bgLog": "#140e26",
            "bgInput": "#241a4d",
            "fgEvent": "#9d8ad0",
            "fgMessage": "#e9e2ff",
            "fgPrivate": "#5cf6ff",
            "fgNotice": "#7dffc4",
            "fgAction": "#ff6ee7",
            "fgHighlight": "#ffffff",
            "fgSelf": "#b8f0ff"
        }
    }
}

// --- theme token schema -----------------------------------------------------
// Version of the token set. Bump this whenever a token is added or removed —
// and mirror the bump in [UI] ThemeSchemaVersion (cpp/kircconfig.cpp) so a
// config that already names a theme is re-examined instead of silently
// keeping an older set (the v2->v3 precedent: a user sat on Oxygen for weeks
// because the migration gate never re-examined the stored id).
var THEME_SCHEMA_VERSION = 4

// Every token the engine can read, section by section. A built-in theme must
// define EXACTLY this set: a missing token silently renders the fallback, and
// an extra token is a typo that never applies. qml-tests/check-theme-tokens.py
// enumerates this table against every themes/*.json and every builtin below
// and fails on either.
var THEME_TOKENS = {
    "root": [
        "id",
        "name",
        "schema",
        "mode"
    ],
    "bubble": [
        "radius",
        "spacing",
        "groupSpacing",
        "tailRadius",
        "maxWidthFraction",
        "selfColor",
        "otherColor"
    ],
    "dense": [
        "lineSpacing"
    ],
    "avatar": [
        "enabled",
        "size"
    ],
    "grouping": [
        "enabled",
        "windowMinutes"
    ],
    "motion": [
        "enabled",
        "duration"
    ],
    "sidebar": [
        "width"
    ],
    "fonts": [
        "messageSize",
        "timestampSize",
        "nickSize"
    ],
    "colors": [
        "nickSatMin",
        "nickSatMax",
        "nickLightnessDark",
        "nickLightnessLight",
        "linkify",
        "highlightIsBold",
        "linkColor"
    ],
    "surfaces": [
        "surface",
        "surfaceAlt",
        "sidebarSurface",
        "cardBackground",
        "cardBorder",
        "cardRadius",
        "cardPadding",
        "rowRadius",
        "rowHover",
        "rowSelected",
        "rowHeight",
        "accent",
        "accentText",
        "mutedText",
        "sectionHeader",
        "sectionHeaderSize",
        "eventText",
        "eventSize",
        "statusOnline",
        "statusAway",
        "statusOffline",
        "unreadBadge",
        "unreadBadgeText",
        "inputRadius",
        "shadowOpacity",
        "headerHeight"
    ],
    "terminal": [
        "fontFamily",
        "gutterWidth",
        "nickColumn",
        "ruleColor",
        "fgPrimary",
        "fgDim",
        "fgAccent",
        "fgWarn",
        "bgPanel",
        "bgLog",
        "bgInput",
        "fgEvent",
        "fgMessage",
        "fgPrivate",
        "fgNotice",
        "fgAction",
        "fgHighlight",
        "fgSelf"
    ]
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
