// SPDX-License-Identifier: GPL-2.0-or-later
//
// ThemeEngine — kIRC's QML-side theme manager.
//
// NOTE ON FILE I/O: a QML sandbox cannot read ~/.config/kIRC/themes/*.json.
// The C++ side reads those files (KDE convention: ~/.config/kIRC/themes/) and
// hands the parsed object (or the raw JSON text) to applyThemeJson().
//
// Imported everywhere as the `ThemeEngine` singleton (see qmldir):
//     color: ThemeEngine.nickColor(nick, darkBackground)
//
// The default theme ("breeze") is the modern bubble look. Every layout knob
// the UI reads lives here as a flat, bindable property so switching themes
// repaints the whole window without any manual signalling.

pragma Singleton

import QtQuick

import "Theme.js" as ThemeLib

QtObject {
    id: engine

    // --- active theme ------------------------------------------------------
    // Raw merged theme object. Assigning a fresh object re-evaluates every
    // binding that reads the flat properties below.
    property var theme: ThemeLib.cloneTheme(null)

    readonly property string themeId: theme.id
    readonly property string themeName: theme.name
    readonly property string mode: theme.mode

    // --- flat, bindable views into `theme` ---------------------------------
    // MessageDelegate / ChatPage bind to these directly so that a theme switch
    // repaints without any manual signalling.
    readonly property real bubbleRadius: theme.bubble.radius
    readonly property real bubbleSpacing: theme.bubble.spacing
    readonly property real bubbleGroupSpacing: theme.bubble.groupSpacing
    readonly property real bubbleTailRadius: theme.bubble.tailRadius
    readonly property real bubbleMaxWidthFraction: theme.bubble.maxWidthFraction
    readonly property string selfColor: theme.bubble.selfColor
    readonly property string otherColor: theme.bubble.otherColor

    readonly property real denseLineSpacing: theme.dense.lineSpacing

    readonly property bool avatarEnabled: theme.avatar.enabled
    readonly property real avatarSize: theme.avatar.size

    readonly property bool groupingEnabled: theme.grouping.enabled
    readonly property int groupingWindowMinutes: theme.grouping.windowMinutes

    readonly property bool motionEnabled: theme.motion.enabled
    readonly property int motionDuration: theme.motion.enabled ? theme.motion.duration : 0

    readonly property real sidebarWidth: theme.sidebar.width

    readonly property int messageSize: theme.fonts.messageSize
    readonly property int timestampSize: theme.fonts.timestampSize
    readonly property int nickSize: theme.fonts.nickSize

    readonly property real nickSatMin: theme.colors.nickSatMin
    readonly property real nickSatMax: theme.colors.nickSatMax
    readonly property real nickLightnessDark: theme.colors.nickLightnessDark
    readonly property real nickLightnessLight: theme.colors.nickLightnessLight

    readonly property bool linkify: theme.colors.linkify
    readonly property bool highlightIsBold: theme.colors.highlightIsBold
    readonly property string linkColor: theme.colors.linkColor

    // Ids the app can offer in a theme picker (built-ins + anything C++ adds).
    property var availableThemeIds: ThemeLib.BUILTIN_IDS.slice()
    property string configError: ""
    property int fontDelta: 0

    // --- theme application -------------------------------------------------

    // Accepts either an already-parsed object or raw JSON text. Unknown keys
    // are kept, missing keys fall back to defaults, bad JSON is reported in
    // configError and leaves the current theme untouched.
    function applyThemeJson(json)
    {
        var parsed = json
        if (typeof json === "string") {
            try {
                parsed = JSON.parse(json)
            } catch (e) {
                engine.configError = qsTr("Invalid theme JSON: %1").arg(e)
                return engine.configError
            }
        }
        if (parsed === null || typeof parsed !== "object") {
            engine.configError = qsTr("Theme JSON must be an object")
            return engine.configError
        }
        engine.configError = ""
        engine.theme = ThemeLib.mergeTheme(parsed)
        return ""
    }

    // Load one of the compiled-in themes by id (breeze, breeze-classic,
    // oxygen, neon). Legacy ids are still accepted. Returns "" on success, an
    // error string otherwise.
    function applyBuiltinTheme(id)
    {
        var key = ThemeLib.canonicalId(id)
        if (!ThemeLib.builtins.hasOwnProperty(key)) {
            engine.configError = qsTr("Unknown built-in theme: %1").arg(id)
            return engine.configError
        }
        engine.configError = ""
        engine.theme = ThemeLib.cloneTheme(ThemeLib.builtins[key])
        return ""
    }

    function applyThemeObject(obj)
    {
        return applyThemeJson(obj)
    }

    // Human-readable label for a theme id (built-ins; unknown ids fall back to
    // the id itself so C++-supplied themes still show up in a picker).
    function themeDisplayName(id)
    {
        var key = ThemeLib.canonicalId(id)
        if (ThemeLib.builtins.hasOwnProperty(key)) {
            return ThemeLib.builtins[key].name
        }
        return id
    }

    function reset()
    {
        engine.configError = ""
        engine.theme = ThemeLib.cloneTheme(null)
    }

    // --- helpers -----------------------------------------------------------

    // Parses "#rgb" / "#rrggbb" into {r,g,b} in 0..1, or null.
    // Real QML colour properties arrive as QColor (with .r/.g/.b already), so
    // this is only needed so the helper also accepts plain strings (theme JSON
    // colours, unit tests).
    function parseHexColor(s)
    {
        var h = String(s).trim()
        if (h.charAt(0) === "#") {
            h = h.substring(1)
        }
        var r
        var g
        var b
        if (h.length === 3) {
            r = parseInt(h.charAt(0) + h.charAt(0), 16)
            g = parseInt(h.charAt(1) + h.charAt(1), 16)
            b = parseInt(h.charAt(2) + h.charAt(2), 16)
        } else if (h.length >= 6) {
            r = parseInt(h.substring(0, 2), 16)
            g = parseInt(h.substring(2, 4), 16)
            b = parseInt(h.substring(4, 6), 16)
        } else {
            return null
        }
        if (isNaN(r) || isNaN(g) || isNaN(b)) {
            return null
        }
        return {"r": r / 255.0, "g": g / 255.0, "b": b / 255.0}
    }

    // Perceived luminance of a QML colour (0 = black, 1 = white).
    function luminanceOf(c)
    {
        if (c === undefined || c === null) {
            return 0.0
        }
        if (typeof c === "string") {
            c = parseHexColor(c)
            if (c === null) {
                return 0.0
            }
        }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    // True when the given background colour is dark. Callers pass
    // Kirigami.Theme.backgroundColor because the attached property must be
    // read from inside an Item to inherit the right colorSet.
    function isDark(background)
    {
        return luminanceOf(background) < 0.5
    }

    // Deterministic nick colour. `dark` is normally
    // ThemeEngine.isDark(Kirigami.Theme.backgroundColor).
    function nickColor(nick, dark)
    {
        var p = ThemeLib.nickColorParams(nick, dark, engine.theme)
        return Qt.hsla(p.hue, p.sat, p.light, 1.0)
    }

    // CSS string variant, for the rare case where Qt.hsla is not available
    // (e.g. building markup for a RichText label).
    function nickColorString(nick, dark)
    {
        var p = ThemeLib.nickColorParams(nick, dark, engine.theme)
        return "hsla(" + Math.round(p.hue * 360) + ", " +
               Math.round(p.sat * 100) + "%, " + Math.round(p.light * 100) + "%, 1)"
    }

    // First letter drawn inside an avatar circle.
    function initial(nick)
    {
        return ThemeLib.nickInitial(nick)
    }

    // Black or white — whichever stays readable on `background`. Used for the
    // text inside nick-coloured avatars and glyph tiles.
    function contrastingTextColor(background)
    {
        return isDark(background) ? "#ffffff" : "#1b1e20"
    }

    // Same colour at a different opacity (colour stays theme-derived).
    function withAlpha(c, alpha)
    {
        if (c === undefined || c === null) {
            return Qt.rgba(0, 0, 0, 0)
        }
        return Qt.rgba(c.r, c.g, c.b, alpha)
    }

    // Absolute point size when the theme sets one, otherwise the platform
    // default handed in by the caller (Kirigami.Theme.defaultFont.pointSize).
    // 0 / negative => inherit.
    function resolvePointSize(configured, basePointSize)
    {
        var base = (configured > 0) ? configured : basePointSize
        return Math.max(6, base + engine.fontDelta)
    }

    // Avatar diameter in pixels: the theme can pin it, otherwise it scales
    // with the grid.
    function avatarSizeFor(gridUnit)
    {
        return engine.avatarSize > 0 ? engine.avatarSize : Math.round(gridUnit * 1.9)
    }

    // Sidebar width in pixels: the theme can pin it, otherwise it scales.
    function sidebarWidthFor(gridUnit)
    {
        return engine.sidebarWidth > 0 ? engine.sidebarWidth : Math.round(gridUnit * 13)
    }

    // Escape + (optionally) linkify a message body. Never fetches anything.
    // `linkCss` is an optional "#rrggbb" used to tint links with the theme
    // accent (see ThemeEngine.cssColor()).
    function formatMessage(text, linkCss)
    {
        return engine.linkify ? ThemeLib.linkify(text, linkCss) : ThemeLib.escapeHtml(text)
    }

    // "#rrggbb" for a QML colour (or a "#rgb"/"#rrggbb" string), so it can be
    // embedded in the RichText the delegates render. "" for anything unusable.
    function cssColor(c)
    {
        if (c === undefined || c === null || c === "") {
            return ""
        }
        if (typeof c === "string") {
            c = parseHexColor(c)
            if (c === null) {
                return ""
            }
        }
        function hex(v) {
            var n = Math.round(Math.max(0, Math.min(1, v)) * 255)
            return (n < 16 ? "0" : "") + n.toString(16)
        }
        return "#" + hex(c.r) + hex(c.g) + hex(c.b)
    }

    // Colours used for the two bubble flavours; empty theme colours fall back
    // to Kirigami's palette so the theme stays coherent with the desktop.
    function selfBubbleColor(fallback)
    {
        return engine.selfColor !== "" ? engine.selfColor : fallback
    }

    function otherBubbleColor(fallback)
    {
        return engine.otherColor !== "" ? engine.otherColor : fallback
    }

    function linkColorValue(fallback)
    {
        return engine.linkColor !== "" ? engine.linkColor : fallback
    }

    // --- message grouping / hashing ----------------------------------------

    // Exposed for tests / debugging.
    function hashNick(nick)
    {
        return ThemeLib.djb2(nick)
    }

    // "HH:MM[:SS]" -> minutes since midnight, or -1.
    function parseTimestamp(ts)
    {
        return ThemeLib.parseTimestampMinutes(ts)
    }

    // Do `row` and `prev` (objects with nick/timestamp/isSelf) belong to the
    // same visual group? Honours the active theme's grouping window.
    function grouped(prev, row)
    {
        if (!engine.groupingEnabled) {
            return false
        }
        return ThemeLib.rowsAreGrouped(prev, row, engine.groupingWindowMinutes)
    }
}
