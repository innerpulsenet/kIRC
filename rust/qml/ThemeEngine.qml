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

    // --- surfaces (Fluent layered look) ------------------------------------
    // Colour tokens are strings and may be "" meaning "fall back to the
    // Kirigami palette at the call site" (see the *Color() resolvers below).
    // Geometry tokens carry the theme character and always have a real value.
    readonly property string surface: theme.surfaces.surface
    readonly property string surfaceAlt: theme.surfaces.surfaceAlt
    readonly property string sidebarSurface: theme.surfaces.sidebarSurface
    readonly property string cardBackground: theme.surfaces.cardBackground
    readonly property string cardBorder: theme.surfaces.cardBorder
    readonly property real cardRadius: theme.surfaces.cardRadius
    readonly property real cardPadding: theme.surfaces.cardPadding
    readonly property real rowRadius: theme.surfaces.rowRadius
    readonly property string rowHover: theme.surfaces.rowHover
    readonly property string rowSelected: theme.surfaces.rowSelected
    readonly property real rowHeight: theme.surfaces.rowHeight
    readonly property string accent: theme.surfaces.accent
    readonly property string accentText: theme.surfaces.accentText
    readonly property string mutedText: theme.surfaces.mutedText
    readonly property string sectionHeader: theme.surfaces.sectionHeader
    readonly property int sectionHeaderSize: theme.surfaces.sectionHeaderSize
    readonly property string eventText: theme.surfaces.eventText
    readonly property int eventSize: theme.surfaces.eventSize
    readonly property string statusOnline: theme.surfaces.statusOnline
    readonly property string statusAway: theme.surfaces.statusAway
    readonly property string statusOffline: theme.surfaces.statusOffline
    readonly property string unreadBadge: theme.surfaces.unreadBadge
    readonly property string unreadBadgeText: theme.surfaces.unreadBadgeText
    readonly property real inputRadius: theme.surfaces.inputRadius
    readonly property real shadowOpacity: theme.surfaces.shadowOpacity
    readonly property real headerHeight: theme.surfaces.headerHeight

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

    // --- surface resolvers --------------------------------------------------
    // Every colour token above may be "" (theme says "use the desktop
    // palette"). The delegate/pages pass their Kirigami fallback in; a fixed
    // theme colour (neon) wins when set. Geometry tokens need no resolver.
    function surfaceColor(fallback)
    {
        return engine.surface !== "" ? engine.surface : fallback
    }

    function surfaceAltColor(fallback)
    {
        return engine.surfaceAlt !== "" ? engine.surfaceAlt : fallback
    }

    function sidebarSurfaceColor(fallback)
    {
        return engine.sidebarSurface !== "" ? engine.sidebarSurface : fallback
    }

    function cardBackgroundColor(fallback)
    {
        return engine.cardBackground !== "" ? engine.cardBackground : fallback
    }

    function cardBorderColor(fallback)
    {
        return engine.cardBorder !== "" ? engine.cardBorder : fallback
    }

    function rowHoverColor(fallback)
    {
        return engine.rowHover !== "" ? engine.rowHover : fallback
    }

    function rowSelectedColor(fallback)
    {
        return engine.rowSelected !== "" ? engine.rowSelected : fallback
    }

    function accentColor(fallback)
    {
        return engine.accent !== "" ? engine.accent : fallback
    }

    function accentTextColor(fallback)
    {
        return engine.accentText !== "" ? engine.accentText : fallback
    }

    function mutedTextColor(fallback)
    {
        return engine.mutedText !== "" ? engine.mutedText : fallback
    }

    function sectionHeaderColor(fallback)
    {
        return engine.sectionHeader !== "" ? engine.sectionHeader : fallback
    }

    function eventTextColor(fallback)
    {
        return engine.eventText !== "" ? engine.eventText : fallback
    }

    function statusOnlineColor(fallback)
    {
        return engine.statusOnline !== "" ? engine.statusOnline : fallback
    }

    function statusAwayColor(fallback)
    {
        return engine.statusAway !== "" ? engine.statusAway : fallback
    }

    function statusOfflineColor(fallback)
    {
        return engine.statusOffline !== "" ? engine.statusOffline : fallback
    }

    function unreadBadgeColor(fallback)
    {
        return engine.unreadBadge !== "" ? engine.unreadBadge : fallback
    }

    function unreadBadgeTextColor(fallback)
    {
        return engine.unreadBadgeText !== "" ? engine.unreadBadgeText : fallback
    }

    // Absolute point size for the section headers / event rows: the theme
    // can pin one, otherwise it derives from the platform default handed in
    // by the caller. 0 / negative => derive.
    function resolveSectionHeaderSize(basePointSize)
    {
        var base = (engine.sectionHeaderSize > 0) ? engine.sectionHeaderSize : Math.max(1, basePointSize - 1)
        return Math.max(6, base + engine.fontDelta)
    }

    function resolveEventSize(basePointSize)
    {
        var base = (engine.eventSize > 0) ? engine.eventSize : Math.max(1, basePointSize - 1)
        return Math.max(6, base + engine.fontDelta)
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

    // True when the clock runs backwards between the two preformatted "HH:MM"
    // stamps (day rollover). Drives the centred day-separator pill.
    function dayBoundary(prevTs, ts)
    {
        return ThemeLib.dayBoundaryMinutes(prevTs, ts)
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
