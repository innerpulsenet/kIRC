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
// TERMINAL LOOK: every built-in theme is a dense monospace palette
// (mode "dense" — `mode` can never be "bubble" any more; mergeTheme coerces
// it). On top of the historical tokens this engine exposes the terminal
// tokens the dense renderer reads: fontFamily, gutterWidth, nickColumn,
// ruleColor, fg*, bg*. Every token has a Kirigami-palette fallback so a theme
// with empty colours still renders coherently with the desktop scheme.

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
    // Always "dense" for anything that went through mergeTheme.
    readonly property string mode: theme.mode
    // Token-set schema of the active theme (4 = per-kind message tokens).
    // A theme file written against an older schema still loads (missing tokens
    // fall back to the TUI defaults) — this reports what the *active* theme
    // declares, so the settings surface can say a user theme is outdated.
    readonly property int themeSchema: (typeof theme.schema === "number")
        ? theme.schema
        : ThemeLib.THEME_SCHEMA_VERSION
    // The token schema this build ships (Theme.js THEME_SCHEMA_VERSION). Bump
    // it when tokens are added/removed, together with [UI]
    // ThemeSchemaVersion in cpp/kircconfig.cpp, so a config that already
    // names a theme is re-examined instead of silently keeping the old set.
    readonly property int themeSchemaVersion: ThemeLib.THEME_SCHEMA_VERSION

    // --- flat, bindable views into `theme` ---------------------------------
    // MessageDelegate / ChatPage bind to these directly so that a theme switch
    // repaints without any manual signalling. The bubble* tokens stay for
    // compatibility (a dense theme reports flat values); nothing renders a
    // bubble any more.
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

    // --- terminal tokens (dense IRC look) ----------------------------------
    // These are the tokens the console layout is built from.  They all have
    // real defaults in the built-in themes; a theme may leave a colour empty,
    // which means "use the palette fallback at the call site" (see the *Color
    // resolvers below).

    /// Monospace family used by every surface.  `fontFamilyOverride` is the
    /// user's settings choice; "" means "whatever the theme says".
    property string fontFamilyOverride: ""
    readonly property string fontFamily: engine.fontFamilyOverride !== ""
        ? engine.fontFamilyOverride
        : ((theme.terminal.fontFamily !== "" && theme.terminal.fontFamily !== undefined)
           ? theme.terminal.fontFamily
           : "monospace")
    readonly property bool fontFamilyIsCustom: engine.fontFamilyOverride !== ""

    /// Fixed pixel width of the `[HH:MM]` time gutter.  0 = derive it from the
    /// font metrics at the call site (see resolveGutterWidth()).
    readonly property real gutterWidth: theme.terminal.gutterWidth

    /// Characters to pad the nick to in the message log.  0 = no padding.
    readonly property int nickColumn: theme.terminal.nickColumn

    /// Box-drawing / separator rules.
    readonly property string ruleColor: theme.terminal.ruleColor
    /// Main text colour.
    readonly property string fgPrimary: theme.terminal.fgPrimary
    /// Timestamps, events, secondary text.
    readonly property string fgDim: theme.terminal.fgDim
    /// Highlights, selection marker, prompt.
    readonly property string fgAccent: theme.terminal.fgAccent
    /// Errors, join failures, disconnects.
    readonly property string fgWarn: theme.terminal.fgWarn
    /// System/event rows: joins, parts, MOTD, command replies (the console's
    /// `* …` lines). Distinct from fgDim so timestamps and events can differ.
    readonly property string fgEvent: theme.terminal.fgEvent
    /// Channel message body.
    readonly property string fgMessage: theme.terminal.fgMessage
    /// Query (private) message body.
    readonly property string fgPrivate: theme.terminal.fgPrivate
    /// NOTICE body (server-wide notices and notices in queries).
    readonly property string fgNotice: theme.terminal.fgNotice
    /// CTCP ACTION (`/me`) body.
    readonly property string fgAction: theme.terminal.fgAction
    /// Text of a row that highlighted your nick (the bar uses fgAccent).
    readonly property string fgHighlight: theme.terminal.fgHighlight
    /// Own lines' body text (the nick keeps fgAccent).
    readonly property string fgSelf: theme.terminal.fgSelf
    /// Sidebar / people panel surface.
    readonly property string bgPanel: theme.terminal.bgPanel
    /// Message log surface.
    readonly property string bgLog: theme.terminal.bgLog
    /// Input bar surface.
    readonly property string bgInput: theme.terminal.bgInput

    // --- surfaces (kept for the surrounding chrome) ------------------------
    // Colour tokens are strings and may be "" meaning "fall back to the
    // Kirigami palette at the call site" (see the *Color() resolvers below).
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

    // --- glass surfacing (in-app frosted glass over the console) ------------
    // The sheet state + the colours every GlassSurface derives from. All of it
    // is computed from the ACTIVE theme (its panel/log/input surfaces + accent)
    // so all ten themes gain glass with no theme-schema bump and no per-theme
    // tokens. Nothing here is persisted: main.qml syncs these five properties
    // from KircConfig's [UI] Glass* keys, the settings pane writes them.
    //
    // With `glassEffects` false, GlassSurface renders nothing at all, so the
    // whole UI is pixel-identical to the pre-glass build.
    //
    // Frosting is IN-APP only: it blurs the app's own static underlays. kIRC
    // does not — and this phase deliberately does not — blur whatever sits
    // behind the window.
    property bool glassEffects: true
    property bool glassBlur: true
    property bool glassSheen: true
    property bool glassEdges: true

    /// 1..100, clamped on assignment (KircConfig clamps on load/save too, so a
    /// hand-edited kirc.conf cannot push the derived values out of range).
    property int glassIntensity: 60
    onGlassIntensityChanged: {
        var c = engine.clampGlassIntensity(engine.glassIntensity)
        if (c !== engine.glassIntensity) {
            engine.glassIntensity = c
        }
    }

    function clampGlassIntensity(v)
    {
        var n = Number(v)
        if (isNaN(n)) {
            return 60
        }
        return Math.max(1, Math.min(100, Math.round(n)))
    }

    /// Intensity as 0..1 — every derived alpha/radius below scales with it.
    readonly property real glassAmount: engine.glassIntensity / 100.0

    // RGB components of a theme colour token (string) or a QColor; null when
    // unusable. Internal helper for the mixes below.
    function rgbOf(c)
    {
        if (c === undefined || c === null || c === "") {
            return null
        }
        if (typeof c === "string") {
            return parseHexColor(c)
        }
        if (c.r === undefined) {
            return null
        }
        return {"r": c.r, "g": c.g, "b": c.b}
    }

    /// Linear mix: t = 0 -> a, t = 1 -> b. Either side may be a theme colour
    /// string or a QColor; an unusable side falls back to the other.
    function mixRgb(a, b, t)
    {
        var ca = rgbOf(a)
        var cb = rgbOf(b)
        if (ca === null) {
            ca = cb === null ? {"r": 0, "g": 0, "b": 0} : cb
        }
        if (cb === null) {
            cb = ca
        }
        return Qt.rgba(ca.r + (cb.r - ca.r) * t,
                       ca.g + (cb.g - ca.g) * t,
                       ca.b + (cb.b - ca.b) * t, 1.0)
    }

    function lightenRgb(c, amount)
    {
        return mixRgb(c, Qt.rgba(1, 1, 1, 1), amount)
    }

    function darkenRgb(c, amount)
    {
        return mixRgb(c, Qt.rgba(0, 0, 0, 1), amount)
    }

    /// The colour the glass tints derive from: the active theme's panel
    /// colour, then its log, then its input surface. Themes that leave every
    /// surface token empty (breeze follows the desktop palette) fall back to a
    /// neutral black; their call sites pass their resolved palette colour to
    /// glassFillFor() instead, so glass follows the scheme there too.
    readonly property color glassBase: {
        var candidates = [theme.terminal.bgPanel, theme.terminal.bgLog,
                          theme.terminal.bgInput, theme.surfaces.surface]
        for (var i = 0; i < candidates.length; ++i) {
            var rgb = rgbOf(candidates[i])
            if (rgb !== null) {
                return Qt.rgba(rgb.r, rgb.g, rgb.b, 1.0)
            }
        }
        return Qt.rgba(0, 0, 0, 1.0)
    }

    /// The theme accent the lit edges and the sheen are tinted with.
    readonly property color glassAccent: {
        var a = rgbOf(theme.terminal.fgAccent)
        if (a === null) {
            a = rgbOf(theme.surfaces.accent)
        }
        if (a === null) {
            return Qt.rgba(1, 1, 1, 1)
        }
        return Qt.rgba(a.r, a.g, a.b, 1.0)
    }

    /// True when the theme's base surface reads dark; drives the grain colour
    /// (light grain on dark glass, dark grain on light glass).
    readonly property bool glassBaseIsDark: luminanceOf(engine.glassBase) < 0.5

    /// Translucent tint for one area: pass the colour that area would have
    /// WITHOUT glass (a resolved panel/log/input colour — see the call sites).
    /// `strong` is the less translucent variant for small floating surfaces
    /// (the "[ new messages ]" pill, the join dialog) where legibility wants
    /// more body behind the text.
    function glassFillFor(base, strong)
    {
        var rgb = rgbOf(base)
        if (rgb === null) {
            rgb = rgbOf(engine.glassBase)
        }
        if (rgb === null) {
            rgb = {"r": 0, "g": 0, "b": 0}
        }
        var a = strong ? (0.55 + 0.40 * engine.glassAmount)
                       : (0.30 + 0.45 * engine.glassAmount)
        return Qt.rgba(rgb.r, rgb.g, rgb.b, a)
    }

    // The glass colour set, derived from the active theme + intensity. The
    // frozen names (p8 operator notes): glassFill, glassFillStrong,
    // glassEdgeLight, glassEdgeDark, glassSheenTint, glassGrain, glassShadow.
    readonly property color glassFill: engine.glassFillFor(engine.glassBase, false)
    readonly property color glassFillStrong: engine.glassFillFor(engine.glassBase, true)
    readonly property color glassEdgeLight: engine.withAlpha(
        engine.lightenRgb(engine.glassAccent, 0.62), 0.22 + 0.30 * engine.glassAmount)
    readonly property color glassEdgeDark: Qt.rgba(0, 0, 0, 0.28 + 0.34 * engine.glassAmount)
    readonly property color glassSheenTint: engine.withAlpha(
        engine.lightenRgb(engine.glassAccent, 0.72), 0.05 + 0.10 * engine.glassAmount)
    readonly property color glassGrain: engine.withAlpha(
        engine.glassBaseIsDark ? Qt.rgba(1, 1, 1, 1) : Qt.rgba(0, 0, 0, 1),
        0.012 + 0.033 * engine.glassAmount)
    readonly property color glassShadow: Qt.rgba(0, 0, 0, 0.20 + 0.32 * engine.glassAmount)

    // Derived geometry for the sheet (used by GlassSurface).
    readonly property real glassFrostOpacity: 0.45 + 0.55 * engine.glassAmount
    readonly property real glassBlurAmount: 0.55 + 0.45 * engine.glassAmount
    readonly property int glassBlurMax: Math.round(8 + 40 * engine.glassAmount)
    readonly property real glassSheenOpacity: 0.35 + 0.65 * engine.glassAmount

    // Ids the app can offer in a theme picker (built-ins + anything C++ adds).
    property var availableThemeIds: ThemeLib.BUILTIN_IDS.slice()
    property string configError: ""
    property int fontDelta: 0

    // Curated monospace families for the settings picker.  "monospace" is the
    // Qt generic and always resolves; the rest are filtered against the fonts
    // actually installed (Qt.fontFamilies(), best-effort — when that is not
    // available the curated list is shown unfiltered).  A font stored by the
    // user that is not in the list is prepended so the current choice is
    // always visible.
    function monospaceFamilies()
    {
        var preferred = ["monospace", "DejaVu Sans Mono", "Liberation Mono",
                         "Noto Sans Mono", "Ubuntu Mono", "Fira Code",
                         "JetBrains Mono", "Hack", "Source Code Pro",
                         "IBM Plex Mono", "Terminus", "Cascadia Mono",
                         "Courier New"]
        var installed = []
        try {
            installed = Qt.fontFamilies()
        } catch (e) {
            installed = []
        }
        var out = []
        for (var i = 0; i < preferred.length; ++i) {
            if (preferred[i] === "monospace" || installed.length === 0
                || installed.indexOf(preferred[i]) >= 0) {
                out.push(preferred[i])
            }
        }
        var current = engine.fontFamily
        if (current.length > 0 && out.indexOf(current) < 0) {
            out.unshift(current)
        }
        return out
    }

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

    // Load one of the compiled-in themes by id (tui, phosphor, amber, ice,
    // breeze, bbs, c64, vt, ega, synthwave). Retired ids are aliased to `tui`,
    // legacy ids still resolve. Returns "" on success, an error string
    // otherwise.
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

    // Resolve a legacy/aliased id to the id `themeId` reports after applying it.
    // (The settings picker compares against `themeId`, which is canonical.)
    function canonicalId(id)
    {
        return ThemeLib.canonicalId(id)
    }

    // True for ids that used to be built-in bubble/glass themes.  The C++
    // schema-3 migration rewrites them to `tui`; at runtime they alias to it.
    function isRetiredThemeId(id)
    {
        return ThemeLib.isRetiredId(id)
    }

    // Preview colours for a theme id — the settings picker's swatch rows.
    // Colour tokens that are empty in the theme ("use the desktop palette")
    // fall back to the caller's palette values, so palette-driven themes still
    // show a usable preview.  Unknown ids preview with the fallbacks.
    function themePreview(id, fallbackAccent, fallbackSurface, fallbackText)
    {
        var key = ThemeLib.canonicalId(id)
        if (!ThemeLib.builtins.hasOwnProperty(key)) {
            return {"accent": fallbackAccent, "surface": fallbackSurface,
                    "bubble": fallbackSurface, "log": fallbackSurface,
                    "panel": fallbackSurface, "input": fallbackSurface,
                    "text": fallbackText, "mode": "dense"}
        }
        var t = ThemeLib.builtins[key]
        var s = t.surfaces
        var term = t.terminal
        function pick(v, fb) {
            return (typeof v === "string" && v.length > 0) ? v : fb
        }
        return {
            "accent": pick(s.accent, fallbackAccent),
            // "surface" and "bubble" are kept for older callers; they now
            // point at the terminal surfaces.
            "surface": pick(s.surface, fallbackSurface),
            "bubble": pick(term.bgInput, pick(s.surfaceAlt, fallbackSurface)),
            "log": pick(term.bgLog, pick(s.surface, fallbackSurface)),
            "panel": pick(term.bgPanel, fallbackSurface),
            "input": pick(term.bgInput, fallbackSurface),
            "text": pick(term.fgPrimary, fallbackText),
            "dim": pick(term.fgDim, fallbackText),
            "mode": t.mode
        }
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

    // First letter of a nick (kept for the channel tiles / person panel).
    function initial(nick)
    {
        return ThemeLib.nickInitial(nick)
    }

    // Pad a nick to the theme's nick column with spaces.  A longer nick is
    // returned unchanged (never truncate a nick).
    function paddedNick(nick)
    {
        return ThemeLib.padNick(nick, engine.nickColumn)
    }

    // Black or white — whichever stays readable on `background`.
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

    // Avatar diameter in pixels (kept for callers that still ask; dense themes
    // report avatarEnabled = false so nothing draws one).
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

    // Message colours for the two flavours (kept for compatibility; dense
    // themes leave both empty so the caller's palette value is used).
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

    // --- terminal resolvers -------------------------------------------------
    // Every terminal colour token may be "" (theme says "use the desktop
    // palette"). The pages and the delegate pass their Kirigami fallback in;
    // a fixed palette theme (tui/phosphor/amber/ice/bbs/c64/vt/ega/synthwave)
    // wins when set.

    function ruleColorValue(fallback)
    {
        return engine.ruleColor !== "" ? engine.ruleColor : fallback
    }

    function fgPrimaryColor(fallback)
    {
        return engine.fgPrimary !== "" ? engine.fgPrimary : fallback
    }

    function fgDimColor(fallback)
    {
        return engine.fgDim !== "" ? engine.fgDim : fallback
    }

    function fgAccentColor(fallback)
    {
        return engine.fgAccent !== "" ? engine.fgAccent : fallback
    }

    function fgWarnColor(fallback)
    {
        return engine.fgWarn !== "" ? engine.fgWarn : fallback
    }

    // --- per-kind message resolvers (schema 4) ------------------------------
    // Same contract as the other terminal resolvers: a fixed palette theme
    // wins, an empty token means "use the caller's fallback" (the caller
    // passes a *distinct* Kirigami role per kind, so even a palette-driven
    // theme keeps the kinds apart).
    function fgEventColor(fallback)
    {
        return engine.fgEvent !== "" ? engine.fgEvent : fallback
    }

    function fgMessageColor(fallback)
    {
        return engine.fgMessage !== "" ? engine.fgMessage : fallback
    }

    function fgPrivateColor(fallback)
    {
        return engine.fgPrivate !== "" ? engine.fgPrivate : fallback
    }

    function fgNoticeColor(fallback)
    {
        return engine.fgNotice !== "" ? engine.fgNotice : fallback
    }

    function fgActionColor(fallback)
    {
        return engine.fgAction !== "" ? engine.fgAction : fallback
    }

    function fgHighlightColor(fallback)
    {
        return engine.fgHighlight !== "" ? engine.fgHighlight : fallback
    }

    function fgSelfColor(fallback)
    {
        return engine.fgSelf !== "" ? engine.fgSelf : fallback
    }

    function bgPanelColor(fallback)
    {
        return engine.bgPanel !== "" ? engine.bgPanel : fallback
    }

    function bgLogColor(fallback)
    {
        return engine.bgLog !== "" ? engine.bgLog : fallback
    }

    function bgInputColor(fallback)
    {
        return engine.bgInput !== "" ? engine.bgInput : fallback
    }

    // Pixel width of the time gutter: the theme's fixed width when set,
    // otherwise the caller's font-derived fallback (e.g. measured advance
    // width of "[00:00]").
    function resolveGutterWidth(fallback)
    {
        return engine.gutterWidth > 0 ? engine.gutterWidth : fallback
    }

    // --- surface resolvers --------------------------------------------------
    // Every colour token above may be "" (theme says "use the desktop
    // palette"). The delegate/pages pass their Kirigami fallback in; a fixed
    // theme colour wins when set. Geometry tokens need no resolver.
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
    // stamps (day rollover).
    function dayBoundary(prevTs, ts)
    {
        return ThemeLib.dayBoundaryMinutes(prevTs, ts)
    }

    // Do `row` and `prev` (objects with nick/timestamp/isSelf) belong to the
    // same visual run? Kept for the harnesses; dense rendering shows every
    // message on its own line.
    function grouped(prev, row)
    {
        if (!engine.groupingEnabled) {
            return false
        }
        return ThemeLib.rowsAreGrouped(prev, row, engine.groupingWindowMinutes)
    }
}
