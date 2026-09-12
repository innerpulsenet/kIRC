// SPDX-License-Identifier: GPL-2.0-or-later
//
// main.qml — kIRC application window.
//
// Owns the single IrcBridge instance (cxx-qt QML element, snake_case members)
// and the page stack: ConnectPage first, then ChatPage once connected.
//
// The GUI is deliberately not responsible for reconnecting or retrying: the
// Rust side owns IRC state, this file only reflects it.
//
// Native integration (all optional, all guarded): the C++ side exposes
//   * `kircConfig` — a KircConfig persisting the last connection profile to
//     ~/.config/kIRC/kirc.conf (cpp/kircconfig.cpp), and
//   * `kircTray`   — a KircTray/KStatusNotifierItem (cpp/kirctray.cpp).
// Neither exists when this file is loaded by the standalone QML harness, so
// every use is null-guarded and the window keeps working without them.
//
// The page stack is forced into single-column mode (`defaultColumnWidth`): a
// chat client should show one page at a time — PageRow's side-by-side desktop
// layout used to leave the connection form visible next to the chat log.

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kirigami.layouts as KirigamiLayouts
import org.kde.kirc

// Bound ids: the compact ASCII header controls below are an inline component,
// which may reference the window's ids (root.*) like any nested component.
pragma ComponentBehavior: Bound

Kirigami.ApplicationWindow {
    id: root

    // Icon theme id for the title bar / task switcher (set imperatively; the
    // QWindow icon property is dynamic on this Kirigami/Qt combo and rejects
    // a static assignment).
    // Window geometry is restored from the persisted prefs when present.
    width: 1024
    height: 700
    // qmllint disable missing-property
    Component.onCompleted: {
        try {
            if (root["icon"] !== undefined && root["icon"] !== null) {
                root["icon"].name = "kirc"
            }
        } catch (e) {
        }
        if (root.appConfig !== null) {
            root.restoreGeometry()
            root.syncSaslMechanismFromConfig()
            if (root.appConfig.themeId.length > 0) {
                ThemeEngine.applyBuiltinTheme(root.appConfig.themeId)
            }
            ThemeEngine.fontDelta = root.appConfig.fontDelta
            root.syncGlassFromConfig()
            root.syncEffectsFromConfig()
        }
    }
    // qmllint enable missing-property
    // Wide/tall enough for the connection form (capped at gridUnit*28 plus
    // page padding) plus the header; a narrower minimum let the form clip.
    minimumWidth: Kirigami.Units.gridUnit * 32
    minimumHeight: Kirigami.Units.gridUnit * 24
    title: root.headerTitle + " — kIRC"
    // One monospace family for the whole window: controls inherit it unless
    // they set their own (the frozen `fontFamily` token).
    font.family: root.monoFamily

    // The one and only bridge object. Children get it through the `bridge`
    // property (QML ids are file-scoped, so it cannot be referenced directly
    // from ConnectPage/ChatPage).
    // The objectName is the handle the C++ side uses (findChild) to reach the
    // bridge after the engine has loaded it — see cpp/main.cpp.
    readonly property IrcBridge bridge: ircBridge

    IrcBridge {
        id: ircBridge
        objectName: "ircBridge"
    }

    // Updated by ChatPage when the user switches channel.
    property string chatChannel: "*server*"

    // One page at a time. PageRow otherwise switches to FixedColumns in
    // wideMode and leaves the connect form sitting beside (or ghosting
    // through) the chat log.
    pageStack.defaultColumnWidth: root.width
    pageStack.columnView.columnResizeMode: KirigamiLayouts.ColumnView.SingleColumn

    // The window provides its own header below; without this the PageRow draws
    // a second toolbar (breadcrumb + navigation) underneath it.
    pageStack.globalToolBar.style: Kirigami.ApplicationHeaderStyle.None

    readonly property color hairline: ThemeEngine.withAlpha(Kirigami.Theme.textColor, 0.12)

    // ---------------------------------------------------------------------- //
    // Retro-terminal chrome tokens (frozen ThemeEngine interface, consumed via
    // their resolvers). The header is monospace, flat and never hardcodes a
    // colour: an empty token means "use the desktop palette".
    // ---------------------------------------------------------------------- //
    readonly property string monoFamily: ThemeEngine.fontFamily
    readonly property color fgPrimary: ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
    readonly property color fgDim: ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
    readonly property color fgAccent: ThemeEngine.fgAccentColor(Kirigami.Theme.highlightColor)
    readonly property color fgWarn: ThemeEngine.fgWarnColor(Kirigami.Theme.negativeTextColor)
    readonly property color bgPanel: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
    readonly property color ruleC: ThemeEngine.ruleColorValue(root.hairline)
    readonly property color hoverFill: ThemeEngine.withAlpha(root.fgPrimary, 0.07)

    /// Colour tokens are strings that may be empty ("desktop palette"); the
    /// ThemeEngine resolvers above always return a usable colour, so the
    /// chrome never needs a literal colour.

    // ---------------------------------------------------------------------- //
    // Persisted profile (KircConfig). `appConfig` is null in harnesses that do
    // not provide the context property.
    //
    // `kircConfig` / `kircTray` are C++ context properties (cpp/kircconfig.cpp,
    // cpp/kirctray.cpp); the existence checks are what let this file also load
    // in the standalone QML harnesses, which is why the unqualified-access lint
    // category is disabled around them.
    // ---------------------------------------------------------------------- //
    // qmllint disable unqualified
    readonly property var appConfig: {
        try {
            return (typeof kircConfig !== "undefined" && kircConfig !== null) ? kircConfig : null
        } catch (e) {
            return null
        }
    }

    readonly property bool minimizeToTray: root.appConfig !== null
                                           ? root.appConfig.minimizeToTray : true

    // True once a StatusNotifierItem host (Plasma panel) is registered, i.e.
    // once hiding the window is actually recoverable. `kircTray` is absent in
    // harnesses, where this stays false.
    readonly property bool trayAvailable: {
        try {
            return (typeof kircTray !== "undefined" && kircTray !== null) ? kircTray.available : false
        } catch (e) {
            return false
        }
    }
    // qmllint enable unqualified

    // Last connection attempt, captured so a *successful* connect can be
    // persisted (the bridge owns the real state; this is just what the user
    // typed).
    property string lastHost: ""
    property int lastPort: 0
    property bool lastTls: true
    property string lastNickname: ""
    property string lastSaslUser: ""
    property string lastSaslPass: ""
    // IRC server password (PASS) for the current attempt/reconnects.  Memory
    // only — never persisted by the window (the settings pane owns KWallet).
    property string lastServerPass: ""
    property int lastSaslMechanism: 0
    property bool userDisconnect: false
    property int reconnectAttempt: 0
    property int reconnectSeconds: 0
    property string lastConnectionError: ""
    // True when the last drop carried an authentication failure (904-907).
    // Cleared on every new attempt; when set, reconnects are skipped unless
    // the reconnectAfterAuthFailure pref allows them.
    property bool lastDropWasAuthFailure: false
    // The bridge-side SASL mechanism id currently in effect.  Initialised
    // from the persisted pref once (plain property + assignment, so no
    // binding loop with appConfig); written back when the user changes it.
    property int saslMechanism: 0

    function syncSaslMechanismFromConfig()
    {
        if (root.appConfig !== null && root.appConfig.saslMechanism !== undefined) {
            root.saslMechanism = root.appConfig.saslMechanism
        }
    }

    // ---------------------------------------------------------------------- //
    // Glass surfacing (cpp/kircconfig.cpp [UI] Glass* keys).
    //
    // The persisted prefs drive the ThemeEngine state every GlassSurface binds
    // to; the settings pane writes both sides live, this sync covers startup
    // and any change that arrives through the config object. A config without
    // the keys (an older file, or a harness double) leaves the ThemeEngine
    // defaults — glass on at 60 — untouched.
    // ---------------------------------------------------------------------- //
    function syncGlassFromConfig()
    {
        if (root.appConfig === null || root.appConfig.glassEffects === undefined) {
            return
        }
        ThemeEngine.glassEffects = root.appConfig.glassEffects
        ThemeEngine.glassIntensity = root.appConfig.glassIntensity
        ThemeEngine.glassBlur = root.appConfig.glassBlur
        ThemeEngine.glassSheen = root.appConfig.glassSheen
        ThemeEngine.glassEdges = root.appConfig.glassEdges
    }

    // qmllint disable unqualified
    Connections {
        target: root.appConfig
        enabled: root.appConfig !== null
        function onGlassEffectsChanged() { root.syncGlassFromConfig() }
        function onGlassIntensityChanged() { root.syncGlassFromConfig() }
        function onGlassBlurChanged() { root.syncGlassFromConfig() }
        function onGlassSheenChanged() { root.syncGlassFromConfig() }
        function onGlassEdgesChanged() { root.syncGlassFromConfig() }
    }
    // qmllint enable unqualified

    // ---------------------------------------------------------------------- //
    // CRT effects (cpp/kircconfig.cpp [UI] Scanlines/… keys) — p10.
    //
    // These five effects are GLOBAL display prefs, like the glass keys: the
    // KircConfig object is the single source of truth (it is what the settings
    // pane and the [effects] popup write), and this window mirrors it into the
    // properties the overlay binds to.  They are deliberately NOT theme tokens,
    // so switching theme can neither enable nor disable them, and a theme file
    // written before this phase cannot carry them.
    //
    // ALL OFF by default, with the subtle amounts the C++ defaults carry
    // (35/30/10/4/8): unlike the glass sheet these sit over the message text,
    // so a fresh install — and any kirc.conf written before these keys — is
    // the plain console, pixel for pixel.
    // ---------------------------------------------------------------------- //
    property bool scanlinesOn: false
    property int scanlineAmount: 35
    property bool vignetteOn: false
    property int vignetteAmount: 30
    property bool grainOn: false
    property int grainAmount: 10
    property bool flickerOn: false
    property int flickerAmount: 4
    property bool humBarOn: false
    property int humBarAmount: 8
    // Glass family (p10 update): the specular chrome gloss.  The rest of the
    // glass family (master, intensity, frost, sheen, edges) keeps living in
    // ThemeEngine — single-sourced, not duplicated here.
    property bool reflectionOn: false
    property int reflectionAmount: 25

    /// True while at least one effect is on.  The overlay Loader is inactive
    /// otherwise, so all-off adds no nodes at all and cannot repaint.
    readonly property bool effectsActive: root.scanlinesOn || root.vignetteOn
                                          || root.grainOn || root.flickerOn
                                          || root.humBarOn || root.reflectionOn

    // ---------------------------------------------------------------------- //
    // Effects capability probe.
    //
    // The effects system assumes a scene graph that can run shader nodes
    // (GlassSurface's frost is a MultiEffect).  Qt Quick's software renderer
    // cannot run shader nodes — and Windows ships it as the default backend
    // (see cpp/main.cpp) — so the window reports what its renderer is and
    // the whole effects system degrades to plain underlays while it is
    // software: the overlays do not instantiate, the saved preferences stay
    // untouched, and the effects UI disables its toggles with the one-line
    // ThemeEngine.effectsUnsupportedReason.
    //
    // GraphicsInfo is an attached property, readable only on an Item inside
    // the rendered window; the ThemeEngine singleton is a QtObject without a
    // window, which is why the probe lives here and only its result is
    // forwarded.  GraphicsInfo.api is Unknown until the scene graph
    // initializes and then updates reactively (verified against Qt 6.11), so
    // the degradation lands the moment software rendering is confirmed, and
    // a hardware backend (KIRC_QUICK_BACKEND=d3d11/opengl) keeps everything
    // exactly as it has always been.
    // ---------------------------------------------------------------------- //
    readonly property bool softwareSceneGraph: GraphicsInfo.api === GraphicsInfo.Software

    Binding {
        target: ThemeEngine
        property: "_backendSoftware"
        value: root.softwareSceneGraph
    }

    // qmllint disable unqualified
    /// Pull every effect pref out of the config object.  A config that predates
    /// the keys leaves the all-off defaults untouched.
    function syncEffectsFromConfig()
    {
        if (root.appConfig === null || root.appConfig.scanlines === undefined) {
            return
        }
        root.scanlinesOn = root.appConfig.scanlines
        root.scanlineAmount = root.appConfig.scanlineAmount
        root.vignetteOn = root.appConfig.vignette
        root.vignetteAmount = root.appConfig.vignetteAmount
        root.grainOn = root.appConfig.grain
        root.grainAmount = root.appConfig.grainAmount
        root.flickerOn = root.appConfig.flicker
        root.flickerAmount = root.appConfig.flickerAmount
        root.humBarOn = root.appConfig.humBar
        root.humBarAmount = root.appConfig.humBarAmount
        root.reflectionOn = root.appConfig.reflection
        root.reflectionAmount = root.appConfig.reflectionAmount
    }

    /// Write the effect prefs back through the config.  The [effects] popup
    /// toggles call this; the settings pane writes the config directly (both
    /// paths land on the same NOTIFY signals, which sync the properties above).
    ///
    /// It covers BOTH families, because the popup owns both: the CRT keys live
    /// in the properties above, and the glass family's four keys are read off
    /// ThemeEngine (their single source of truth — the popup operates the
    /// existing Glass* keys rather than inventing parallel ones).
    function persistEffects()
    {
        if (root.appConfig === null || root.appConfig.scanlines === undefined) {
            return
        }
        root.appConfig.scanlines = root.scanlinesOn
        root.appConfig.scanlineAmount = root.scanlineAmount
        root.appConfig.vignette = root.vignetteOn
        root.appConfig.vignetteAmount = root.vignetteAmount
        root.appConfig.grain = root.grainOn
        root.appConfig.grainAmount = root.grainAmount
        root.appConfig.flicker = root.flickerOn
        root.appConfig.flickerAmount = root.flickerAmount
        root.appConfig.humBar = root.humBarOn
        root.appConfig.humBarAmount = root.humBarAmount
        root.appConfig.reflection = root.reflectionOn
        root.appConfig.reflectionAmount = root.reflectionAmount
        if (root.appConfig.glassEffects !== undefined) {
            root.appConfig.glassEffects = ThemeEngine.glassEffects
            root.appConfig.glassIntensity = ThemeEngine.glassIntensity
            root.appConfig.glassBlur = ThemeEngine.glassBlur
            root.appConfig.glassSheen = ThemeEngine.glassSheen
            root.appConfig.glassEdges = ThemeEngine.glassEdges
        }
        root.appConfig.save()
    }

    /// One CRT row's behaviour: flip the switch, keep the window and kirc.conf
    /// in step.  A software scene graph refuses the write: the overlay cannot
    /// come back, so the persisted prefs must not change either (the popup
    /// rows are disabled; this guard is the belt under them).
    function toggleEffect(name)
    {
        if (!ThemeEngine.effectsSupported) {
            return
        }
        switch (name) {
        case "scanlines": root.scanlinesOn = !root.scanlinesOn; break
        case "vignette": root.vignetteOn = !root.vignetteOn; break
        case "grain": root.grainOn = !root.grainOn; break
        case "flicker": root.flickerOn = !root.flickerOn; break
        case "humBar": root.humBarOn = !root.humBarOn; break
        }
        root.persistEffects()
    }

    /// One GLASS row's behaviour.  Frost/Sheen/Edges are the existing
    /// ThemeEngine keys (no parallel KConfig keys), Reflection is the p10
    /// chrome gloss.  Turning a layer ON while the master is off turns the
    /// master on too, so no row is ever a dead switch.  The same capability
    /// guard as toggleEffect: no writes on a software scene graph.
    function toggleGlassEffect(name)
    {
        if (!ThemeEngine.effectsSupported) {
            return
        }
        var on = false
        switch (name) {
        case "blur":
            ThemeEngine.glassBlur = !ThemeEngine.glassBlur
            on = ThemeEngine.glassBlur
            break
        case "sheen":
            ThemeEngine.glassSheen = !ThemeEngine.glassSheen
            on = ThemeEngine.glassSheen
            break
        case "edges":
            ThemeEngine.glassEdges = !ThemeEngine.glassEdges
            on = ThemeEngine.glassEdges
            break
        case "reflection":
            root.reflectionOn = !root.reflectionOn
            on = root.reflectionOn
            break
        }
        if (on) {
            ThemeEngine.glassEffects = true
        }
        root.persistEffects()
    }

    Connections {
        target: root.appConfig
        enabled: root.appConfig !== null && root.appConfig.scanlines !== undefined
        function onScanlinesChanged() { root.syncEffectsFromConfig() }
        function onScanlineAmountChanged() { root.syncEffectsFromConfig() }
        function onVignetteChanged() { root.syncEffectsFromConfig() }
        function onVignetteAmountChanged() { root.syncEffectsFromConfig() }
        function onGrainChanged() { root.syncEffectsFromConfig() }
        function onGrainAmountChanged() { root.syncEffectsFromConfig() }
        function onFlickerChanged() { root.syncEffectsFromConfig() }
        function onFlickerAmountChanged() { root.syncEffectsFromConfig() }
        function onHumBarChanged() { root.syncEffectsFromConfig() }
        function onHumBarAmountChanged() { root.syncEffectsFromConfig() }
        function onReflectionChanged() { root.syncEffectsFromConfig() }
        function onReflectionAmountChanged() { root.syncEffectsFromConfig() }
    }
    // qmllint enable unqualified

    Timer {
        id: reconnectTimer
        interval: 3000
        repeat: false
        onTriggered: {
            root.reconnectSeconds = 0
            root.tryReconnect()
        }
    }

    Timer {
        id: reconnectCountdown
        interval: 1000
        repeat: true
        running: reconnectTimer.running && root.reconnectSeconds > 0
        onTriggered: root.reconnectSeconds = Math.max(0, root.reconnectSeconds - 1)
    }

    /// Buffer name for the window title.  "*server*" is internal and reads
    /// "Server"; every other buffer is shown exactly as it is typed — a
    /// channel keeps its prefix (`#pain`), a query keeps its nick.
    function channelLabel(target)
    {
        if (target === "*server*") {
            return qsTr("Server")
        }
        return target
    }

    /// Channel prefixes (# & + !). Mirrors ChatPage.isChannel for the header.
    function isChannel(target)
    {
        if (target === undefined || target === null || target === "*server*") {
            return false
        }
        var c = String(target).charAt(0)
        return c === "#" || c === "&" || c === "+" || c === "!"
    }

    // Header/window title.  The settings pane is not a chat buffer, so it
    // names itself instead of borrowing the channel label.
    readonly property string headerTitle: root.pageStack.depth <= 1
        ? qsTr("Connect to IRC")
        : (root.currentPageIsSettings() ? qsTr("Settings")
                                        : root.channelLabel(root.chatChannel))

    function currentPageIsSettings()
    {
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        return page !== null && page !== undefined && page["isKircSettingsPage"] === true
        // qmllint enable missing-property
    }

    readonly property string statusText: {
        switch (root.bridge.connection_state) {
        case 0: return qsTr("Disconnected")
        case 1: return qsTr("Connecting…")
        case 2: return qsTr("Connected")
        }
        return qsTr("Disconnected")
    }

    /// Header status as bracketed terminal text: `[connected]` / `[connecting]`
    /// / `[offline]` — no rounded pill, no dot.
    readonly property string statusTag: {
        if (reconnectTimer.running) {
            return "[" + qsTr("retry %1s").arg(root.reconnectSeconds) + "]"
        }
        switch (root.bridge.connection_state) {
        case 0: return "[" + qsTr("offline") + "]"
        case 1: return "[" + qsTr("connecting") + "]"
        case 2: return "[" + qsTr("connected") + "]"
        }
        return "[" + qsTr("offline") + "]"
    }

    /// Header context line: the buffer as it is typed (`#pain`, a query nick,
    /// or the server console) — there is no coloured glyph tile any more.
    readonly property string headerContextText: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return root.headerTitle
        }
        if (root.chatChannel === "*server*") {
            return qsTr("Server")
        }
        return root.chatChannel
    }

    // Identity line (p9): `nick @ server` is one of the most useful facts in
    // the window, so it is shown once, bold, immediately beside the live
    // status tag — not as dim filler.  The two halves are separate labels so
    // the nick carries the accent colour.  Empty when there is nothing useful
    // to say (connection form, settings pane).
    readonly property string identityNick: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return ""
        }
        return root.bridge.nickname
    }

    /// The ` @ host` half of the identity line; the port/TLS decoration the
    /// bridge appends is dropped (`irc.example.net:6697 (TLS)` reads as the
    /// host alone).  Without a nick it degrades to the bare host.
    readonly property string identityServer: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return ""
        }
        var server = root.bridge.connected_server
        // Strip a conventional host:port suffix, but leave IPv6 literals
        // intact. Splitting at the first colon turned `2001:db8::1` into the
        // misleading identity `2001` while a connection was in progress.
        var firstColon = server.indexOf(":")
        var lastColon = server.lastIndexOf(":")
        var shortServer = firstColon > 0 && firstColon === lastColon
                        ? server.substring(0, firstColon) : server
        if (shortServer.length === 0) {
            return ""
        }
        return root.bridge.nickname.length > 0 ? (" @ " + shortServer) : shortServer
    }

    /// The active channel's topic: dim, trailing, and the first thing to
    /// yield on a narrow window — the identity line above owns the prominence.
    readonly property string headerTopic: {
        if (root.pageStack.depth <= 1 || root.currentPageIsSettings()) {
            return ""
        }
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        if (page && page["currentTopic"] !== undefined && String(page["currentTopic"]).length > 0
                && root.isChannel(root.chatChannel)) {
            return String(page["currentTopic"])
        }
        // qmllint enable missing-property
        return ""
    }

    // Tooltip for the connection status pill ("Connected to …" etc).
    readonly property string statusTip: {
        var server = root.bridge.connected_server
        switch (root.bridge.connection_state) {
        case 2: return server.length > 0 ? qsTr("Connected to %1").arg(server) : qsTr("Connected")
        case 1: return server.length > 0 ? qsTr("Connecting to %1…").arg(server) : qsTr("Connecting…")
        }
        if (reconnectTimer.running) {
            return qsTr("Reconnect attempt %1 in %2 seconds").arg(root.reconnectAttempt).arg(root.reconnectSeconds)
        }
        if (root.lastConnectionError.length > 0) {
            return root.lastConnectionError
        }
        return server.length > 0 ? qsTr("Disconnected from %1").arg(server) : qsTr("Disconnected")
    }

    readonly property color statusColor: root.bridge.connection_state === 2
        ? root.fgAccent
        : (root.bridge.connection_state === 1
           ? root.fgDim
           : root.fgWarn)

    // ---------------------------------------------------------------------- //
    // Close = hide to tray (when a tray is available and the setting is on).
    // The tray's "Quit kIRC" action and the menu item below bypass this by
    // calling Qt.quit()/QCoreApplication::quit(), which never triggers a
    // window close.  The geometry is persisted first, so a re-launch restores
    // the size the user actually closed with.
    onClosing: (close) => {
        root.saveGeometry()
        if (root.trayAvailable && root.minimizeToTray) {
            close.accepted = false
            root.hide()
        }
    }

    onWidthChanged: saveGeometrySoon()
    onHeightChanged: saveGeometrySoon()

    // Coalesced geometry writer: stores the live size (not while hidden to
    // tray) so a restart restores it.
    Timer {
        id: geometryTimer
        interval: 500
        repeat: false
        onTriggered: root.saveGeometry()
    }

    function saveGeometrySoon()
    {
        if (root.appConfig === null || !root.visible) {
            return
        }
        geometryTimer.restart()
    }

    function saveGeometry()
    {
        if (root.appConfig === null || root.appConfig.windowWidth === undefined) {
            return
        }
        if (root.width >= root.minimumWidth && root.height >= root.minimumHeight) {
            root.appConfig.windowWidth = root.width
            root.appConfig.windowHeight = root.height
            root.appConfig.save()
        }
    }

    // ---------------------------------------------------------------------- //
    // Restored geometry.  The persisted size is a *hint*: a stale entry may
    // predate the current minimums, or come from a larger display.  Clamping
    // it to [minimum, available screen] is what keeps the composer and the
    // header from being clipped by a window the layout cannot fit into.
    // ---------------------------------------------------------------------- //

    /// Work area of the window's screen in logical pixels; {0, 0} when the
    /// platform reports no screen (offscreen harnesses).
    function maximumWindowSize()
    {
        var result = {"width": 0, "height": 0}
        var screen = root.screen
        if (screen === undefined || screen === null) {
            return result
        }
        // Qt 6 exposes the work area (panels excluded) as desktopAvailable*.
        // Those are device pixels, while the window is laid out in logical
        // pixels, so scale by the device pixel ratio.
        var w = (screen.desktopAvailableWidth !== undefined && screen.desktopAvailableWidth > 0)
            ? screen.desktopAvailableWidth : screen.width
        var h = (screen.desktopAvailableHeight !== undefined && screen.desktopAvailableHeight > 0)
            ? screen.desktopAvailableHeight : screen.height
        var dpr = (screen.devicePixelRatio > 0) ? screen.devicePixelRatio : 1
        if (w > 0 && h > 0) {
            result.width = Math.round(w / dpr)
            result.height = Math.round(h / dpr)
        }
        return result
    }

    /// Clamp one window dimension to [minimum, maximum]; -1 means "no usable
    /// stored value", which leaves the current size alone.
    function clampWindowDimension(value, minimum, maximum)
    {
        if (value === undefined || value === null || isNaN(value) || value <= 0) {
            return -1
        }
        var v = Math.round(value)
        if (maximum > 0 && v > maximum) {
            v = maximum
        }
        // The minimum wins even on a screen smaller than it: a window whose
        // own layout clips is worse than one the window manager must move.
        return Math.max(minimum, v)
    }

    function restoreGeometry()
    {
        if (root.appConfig === null || root.appConfig.windowWidth === undefined) {
            return
        }
        var screenMax = root.maximumWindowSize()
        var w = root.clampWindowDimension(root.appConfig.windowWidth, root.minimumWidth, screenMax.width)
        var h = root.clampWindowDimension(root.appConfig.windowHeight, root.minimumHeight, screenMax.height)
        if (w > 0) {
            root.width = w
        }
        if (h > 0) {
            root.height = h
        }
    }

    // ---------------------------------------------------------------------- //
    // Header: compact ASCII toolbar. Monospace context line, dim secondary
    // info, bracketed status text and flat `[action]` controls — the page
    // title and back control are re-created here (the default global toolbar
    // stays off).
    // ---------------------------------------------------------------------- //

    /// Flat text control for the header: bracketed ASCII label, accent on
    /// hover, no surface box. Keeps the ToolButton contract (text, tooltip,
    /// click) so every header action behaves exactly as before.
    component HeaderButton: Controls.ToolButton {
        id: headerButton
        display: Controls.AbstractButton.TextOnly
        Layout.alignment: Qt.AlignVCenter
        leftPadding: Kirigami.Units.smallSpacing
        rightPadding: Kirigami.Units.smallSpacing

        contentItem: Controls.Label {
            text: headerButton.text
            color: !headerButton.enabled ? root.fgDim
                   : (headerButton.hovered || headerButton.activeFocus ? root.fgAccent : root.fgPrimary)
            font.family: root.monoFamily
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            color: headerButton.hovered || headerButton.activeFocus ? root.hoverFill : "transparent"
        }
    }

    /// Flat terminal menu row.  The stock popup styling is a modern rounded
    /// light menu — against a black console it reads as a rendering bug, and
    /// its light-theme text colour can land dark-on-dark once the popup
    /// background is themed.
    component TermMenuItem: Controls.MenuItem {
        id: termItem
        font.family: root.monoFamily
        implicitHeight: Math.round(Kirigami.Units.gridUnit * 1.55)
        // The stock check indicator paints from the item's left edge, which
        // lands on top of the first letter once contentItem is replaced — so
        // the mark is drawn as an ASCII checkbox inside the label instead.
        indicator: null
        background: Rectangle {
            color: termItem.highlighted || termItem.activeFocus ? root.hoverFill : "transparent"
        }
        contentItem: Controls.Label {
            leftPadding: Kirigami.Units.smallSpacing * 2
            rightPadding: Kirigami.Units.smallSpacing * 2
            text: termItem.checkable
                ? ((termItem.checked ? "[*] " : "[ ] ") + termItem.text)
                : termItem.text
            font: termItem.font
            color: termItem.enabled
                ? ThemeEngine.fgPrimaryColor(Kirigami.Theme.textColor)
                : ThemeEngine.fgDimColor(Kirigami.Theme.disabledTextColor)
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    header: Controls.ToolBar {
        id: headerBar
        font.family: root.monoFamily

        background: Rectangle {
            color: root.bgPanel

            // Glass sheet (p8): a frosted pane over the header surface. The
            // console rule below is declared after it, so the box-drawing-ish
            // bottom rule keeps painting on top of the glass.
            GlassSurface {
                anchors.fill: parent
                radius: 0
                tint: ThemeEngine.glassFillFor(parent.color)
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: root.ruleC
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            HeaderButton {
                text: "[" + qsTr("back") + "]"
                // [back] leaves the settings pane (back to the chat), or the
                // chat page when the session is down (back to the connection
                // form). While a session is LIVE it is not offered: popping to
                // the form would strand the session behind a screen that
                // cannot reach it, and Disconnect is the control that actually
                // ends a session. (Connectivity outranks convenience here —
                // the guard below re-opens the chat page if one ever lands on
                // the form mid-session.)
                visible: root.pageStack.depth > 1
                         && (root.currentPageIsSettings()
                             || root.bridge.connection_state !== 2)
                onClicked: root.pageStack.pop()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Back to connection settings")
            }

            // Context: the buffer as it is typed (`#pain`, a query nick, or
            // the server console). The coloured glyph tile is gone.
            Controls.Label {
                text: root.headerContextText
                color: root.fgPrimary
                font.family: root.monoFamily
                font.bold: true
                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                elide: Text.ElideRight
                // Never elide below a readable floor: the title yields last.
                Layout.minimumWidth: Math.min(implicitWidth, Math.round(Kirigami.Units.gridUnit * 6))
                Layout.alignment: Qt.AlignVCenter
            }

            // ---- identity: `nick @ server` (p9) --------------------------
            // The account the session is on.  Shown once, bold, next to the
            // status tag; the nick carries the accent so the pair reads as one
            // fact — who you are, and whether it is live.  Plain monospace
            // text: no badge, no pill.
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                visible: root.identityNick.length > 0 || root.identityServer.length > 0
                spacing: 0

                Controls.Label {
                    text: root.identityNick
                    visible: text.length > 0
                    color: root.fgAccent
                    font.family: root.monoFamily
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 10
                    Layout.minimumWidth: 0
                    Layout.alignment: Qt.AlignVCenter
                }

                Controls.Label {
                    text: root.identityServer
                    visible: text.length > 0
                    color: root.fgPrimary
                    font.family: root.monoFamily
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                    Layout.minimumWidth: 0
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            // ---- connection status: bracketed terminal text ----
            Controls.Label {
                Layout.alignment: Qt.AlignVCenter
                text: root.statusTag
                color: root.statusColor
                font.family: root.monoFamily
                font.bold: true

                Accessible.name: root.statusTip
                Accessible.description: root.statusTip

                Controls.ToolTip.visible: statusHover.hovered
                Controls.ToolTip.text: root.statusTip

                HoverHandler {
                    id: statusHover
                }
            }

            // ---- channel topic: dim, trailing, yields first ----------------
            // A fixed cap keeps a long topic from squeezing the controls off
            // the header; below a comfortable width it yields entirely so the
            // buffer title and the identity line stay readable.
            Controls.Label {
                visible: root.headerTopic.length > 0
                         && root.width >= Kirigami.Units.gridUnit * 40
                text: root.headerTopic
                color: root.fgDim
                font.family: root.monoFamily
                font.pointSize: Math.max(1, Kirigami.Theme.defaultFont.pointSize - 1)
                elide: Text.ElideRight
                Layout.maximumWidth: Kirigami.Units.gridUnit * 22
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignVCenter
            }

            // Flexible gutter: the buffer + identity + status + topic cluster
            // stays packed to the left (that is one line of chrome, not a
            // spread layout); everything after it is pushed to the right edge.
            Item {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
            }

            // ---- unread count: `[3]`, opens/clears with the buffers ----
            // Count of unread messages across buffers; clears when the buffers
            // are read (ChatPage calls bridge.mark_read() on open/switch).
            Controls.Label {
                id: unreadLabel
                Layout.alignment: Qt.AlignVCenter
                // Only meaningful once the chat is on screen: on the connect
                // form a stale count from the previous session reads as a
                // mystery badge.
                visible: root.pageStack.depth > 1 && root.bridge.unread_count > 0
                text: "[" + (root.bridge.unread_count > 99 ? "99+" : root.bridge.unread_count) + "]"
                color: root.fgAccent
                font.family: root.monoFamily
                font.bold: true

                Accessible.name: qsTr("%n unread message(s)", "", root.bridge.unread_count)
                Accessible.description: qsTr("Unread messages")

                Controls.ToolTip.visible: unreadHover.hovered
                Controls.ToolTip.text: qsTr("%n unread message(s)", "", root.bridge.unread_count)

                HoverHandler {
                    id: unreadHover
                }

                TapHandler {
                    onTapped: {
                        if (root.pageStack.depth > 1
                                && typeof root.bridge.mark_read === "function") {
                            root.bridge.mark_read()
                        }
                    }
                }
            }

            // ---- toolbar: [search] [theme] [effects] [menu] (p10) ---------
            // Join moved to /join (Ctrl+J) with the menu's Help entry as the
            // discoverable reference; Settings, Disconnect and Exit live in the
            // one [menu].  The nick no longer repeats here: the identity line
            // above is the only place it is shown.  Theme and Effects got their
            // own controls (p10) because both are one-click switches the user
            // reaches for often; the [menu] keeps its Theme row as the
            // discoverable duplicate.
            HeaderButton {
                id: searchButton
                text: "[" + qsTr("search") + "]"
                // Only where there is something to search: the settings pane
                // has no message search, so the button is hidden there instead
                // of being an enabled no-op.
                enabled: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                visible: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                onClicked: root.focusChatSearch()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Search messages (Ctrl+F)")
            }

            // ---- [theme]: the theme list, one click away ------------------
            // The same flat terminal list the [menu] > Theme row opens; this
            // control is where the user looks for it.  It owns `themeMenu`
            // (a Menu declared inside a Menu is auto-added as a submenu row
            // without the TermMenuItem chrome — hence the two-popup layout).
            HeaderButton {
                id: themeButton
                text: "[" + qsTr("theme") + "]"
                onClicked: themeMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Theme")

                Controls.Menu {
                    id: themeMenu
                    title: qsTr("Theme")
                    font.family: root.monoFamily
                    background: Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 12)
                        color: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
                        border.width: 1
                        border.color: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)
                    }

                    // Built-in (compiled-in) themes. Additional themes from
                    // ~/.config/kIRC/themes/ are appended by the C++ side, which
                    // is expected to extend ThemeEngine.availableThemeIds and
                    // call ThemeEngine.applyThemeJson() when one is picked.
                    Instantiator {
                        model: ThemeEngine.availableThemeIds

                        delegate: TermMenuItem {
                            id: themeItem
                            required property string modelData

                            text: ThemeEngine.themeDisplayName(themeItem.modelData)
                            checkable: true
                            checked: ThemeEngine.themeId === themeItem.modelData
                            onTriggered: {
                                ThemeEngine.applyBuiltinTheme(themeItem.modelData)
                                if (root.appConfig !== null) {
                                    root.appConfig.themeId = themeItem.modelData
                                    root.appConfig.save()
                                }
                            }
                        }

                        onObjectAdded: (index, object) => themeMenu.insertItem(index, object)
                        onObjectRemoved: (index, object) => themeMenu.removeItem(object)
                    }
                }
            }

            // ---- [effects]: the one effects control -----------------------
            // ONE system, two families, both global display prefs (KircConfig
            // [UI] keys plus the existing Glass* keys) rather than theme
            // tokens.  The rows are grouped: glass first (Frost, Sheen, Edges,
            // Reflection), then the CRT set, then a row that jumps to the
            // settings pane's Effects section for the intensities.
            //
            // The rows operate the EXISTING glass keys (GlassBlur/Sheen/Edges
            // via ThemeEngine), so the state stays single-sourced; turning one
            // on while the master is off turns the master on, so no row is a
            // dead switch.  The marks are drawn into the label instead of
            // using `checkable` so they cannot go stale behind the menu's
            // internal checked toggling.
            HeaderButton {
                id: effectsButton
                text: "[" + qsTr("effects") + "]"
                onClicked: effectsMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Effects")

                Controls.Menu {
                    id: effectsMenu
                    title: qsTr("Effects")
                    font.family: root.monoFamily
                    background: Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 14)
                        color: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
                        border.width: 1
                        border.color: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)
                    }

                    // Capability caption (software scene graph only).  The
                    // Instantiator exists so the row is absent — not merely
                    // hidden — while the effects are supported: the popup's
                    // row list, and the harness assertions on it, stay
                    // byte-identical there.  When unsupported, the caption is
                    // inserted as the first row and every effect toggle below
                    // goes inert with the labels unchanged; the saved prefs
                    // are not touched.
                    Instantiator {
                        model: ThemeEngine.effectsSupported ? 0 : 1

                        delegate: TermMenuItem {
                            enabled: false
                            text: ThemeEngine.effectsUnsupportedReason
                        }

                        onObjectAdded: (index, object) => effectsMenu.insertItem(0, object)
                        onObjectRemoved: (index, object) => effectsMenu.removeItem(object)
                    }

                    // ---- glass family ------------------------------------
                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (ThemeEngine.glassBlur ? "[*] " : "[ ] ") + qsTr("Frost")
                        onTriggered: root.toggleGlassEffect("blur")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (ThemeEngine.glassSheen ? "[*] " : "[ ] ") + qsTr("Sheen")
                        onTriggered: root.toggleGlassEffect("sheen")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (ThemeEngine.glassEdges ? "[*] " : "[ ] ") + qsTr("Edges")
                        onTriggered: root.toggleGlassEffect("edges")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.reflectionOn ? "[*] " : "[ ] ") + qsTr("Reflection")
                        onTriggered: root.toggleGlassEffect("reflection")
                    }

                    Controls.MenuSeparator {}

                    // ---- CRT family --------------------------------------
                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.scanlinesOn ? "[*] " : "[ ] ") + qsTr("Scanlines")
                        onTriggered: root.toggleEffect("scanlines")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.vignetteOn ? "[*] " : "[ ] ") + qsTr("Vignette")
                        onTriggered: root.toggleEffect("vignette")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.grainOn ? "[*] " : "[ ] ") + qsTr("Grain")
                        onTriggered: root.toggleEffect("grain")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.flickerOn ? "[*] " : "[ ] ") + qsTr("Flicker")
                        onTriggered: root.toggleEffect("flicker")
                    }

                    TermMenuItem {
                        enabled: ThemeEngine.effectsSupported
                        text: (root.humBarOn ? "[*] " : "[ ] ") + qsTr("Hum bar")
                        onTriggered: root.toggleEffect("humBar")
                    }

                    Controls.MenuSeparator {}

                    TermMenuItem {
                        text: qsTr("Effects settings…")
                        onTriggered: root.openEffectsSettings()
                    }
                }
            }

            // ---- the one [menu] (p9) --------------------------------------
            // One control replaces the old [settings]/[menu] pair; its rows
            // hold, in this order, Search, Settings, Theme, Help, then — past
            // the separator — Disconnect and Exit (Exit quits the app).
            HeaderButton {
                id: appMenuButton
                text: "[" + qsTr("menu") + "]"
                onClicked: appMenu.popup()

                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Menu")

                Controls.Menu {
                    id: appMenu
                    font.family: root.monoFamily
                    background: Rectangle {
                        implicitWidth: Math.round(Kirigami.Units.gridUnit * 13)
                        color: ThemeEngine.bgPanelColor(Kirigami.Theme.alternateBackgroundColor)
                        border.width: 1
                        border.color: ThemeEngine.ruleColorValue(Kirigami.Theme.textColor)
                    }

                    // Search is also the one toolbar control: an action worth
                    // keeping in reach when the header is narrow, and the
                    // menu is where a narrow window can still find it.
                    TermMenuItem {
                        text: qsTr("Search")
                        enabled: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                        onTriggered: root.focusChatSearch()
                    }

                    TermMenuItem {
                        text: qsTr("Settings")
                        onTriggered: root.openSettings()
                    }

                    TermMenuItem {
                        text: qsTr("Theme")
                        onTriggered: themeMenu.popup()
                    }

                    TermMenuItem {
                        text: qsTr("Help")
                        // The command reference, printed into the active
                        // buffer exactly as /help does — so /join and the
                        // rest stay discoverable without the old [join].
                        enabled: root.pageStack.depth > 1 && !root.currentPageIsSettings()
                        onTriggered: root.openHelp()
                    }

                    Controls.MenuSeparator {}

                    TermMenuItem {
                        text: qsTr("Disconnect")
                        enabled: root.bridge.connection_state !== 0
                        onTriggered: {
                            root.userDisconnect = true
                            reconnectTimer.stop()
                            root.bridge.disconnect_server()
                        }
                    }

                    TermMenuItem {
                        text: qsTr("Exit")
                        // Qt.quit() ends the application without going through
                        // the window close handler, so it is a real quit even
                        // with hide-to-tray enabled.
                        onTriggered: Qt.quit()
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------- //
    // CRT effects overlay (p10) — painted ABOVE every layer this window owns
    //
    // The page stack, the header and every glass sheet are children of
    // `contentItem`; this Loader is a later sibling with a high z, so log,
    // sidebar, header and composer all sit under the same tube.
    //
    // It is a Loader (not a plain item) on purpose: with every effect OFF it
    // is INACTIVE, so it instantiates nothing and the window is pixel-identical
    // to the pre-effects build — no nodes, no per-frame work.  When an effect
    // is switched on the item appears live, without a restart.
    //
    // The overlay never takes input (its root is disabled and has no handlers)
    // and it never wraps, captures or blurs the scrolling ListView: see
    // ScanlineOverlay.qml for the constraints and how the layers are built.
    // ---------------------------------------------------------------------- //
    Component {
        id: effectsOverlayComponent

        ScanlineOverlay {
            scanlinesOn: root.scanlinesOn
            scanlineAmount: root.scanlineAmount
            vignetteOn: root.vignetteOn
            vignetteAmount: root.vignetteAmount
            grainOn: root.grainOn
            grainAmount: root.grainAmount
            flickerOn: root.flickerOn
            flickerAmount: root.flickerAmount
            humBarOn: root.humBarOn
            humBarAmount: root.humBarAmount
            reflectionOn: root.reflectionOn
            reflectionAmount: root.reflectionAmount
            // Grain, the hum bar and the reflection gloss are light on a dark
            // field and dark on a light one, so they stay visible on `paper`
            // without a theme token.
            backgroundIsDark: ThemeEngine.isDark(root.bgPanel)
            // Reflection may only gloss the window's own static chrome band
            // (the header) — never the log.
            chromeTopHeight: root.header !== null && root.header !== undefined
                             ? root.header.height : 0
            // The same accent language as the glass sheet's sheen.
            glossColor: ThemeEngine.lightenRgb(ThemeEngine.glassAccent, 0.72)
        }
    }

    Loader {
        id: effectsOverlayLoader
        objectName: "effectsOverlayLoader"

        // WHY NOT `parent: root.contentItem`: ApplicationWindow keeps its header
        // and its content area as separate children of the window's own root
        // item, and `contentItem` spans only the area BELOW the header (verified
        // on this stack: contentItem is 1023x673 of a 1023x700 window, with the
        // header at y = -27 from contentItem, both children of the root item).
        // An item inside contentItem therefore can never paint over the header —
        // a parent's whole subtree is painted before a later sibling, whatever
        // the child's z is.  So the overlay is parented to the window's ROOT
        // item (contentItem.parent.parent), which IS the full window, and given
        // the window's geometry explicitly.  If that item tree ever changes
        // shape, the fallback parent is contentItem: the filter still covers the
        // log, the sidebar and the composer, and only the header strip is missed.
        parent: {
            var ci = root.contentItem
            if (ci === null || ci === undefined) {
                return null
            }
            var wrapper = ci.parent
            var top = (wrapper !== null && wrapper !== undefined) ? wrapper.parent : null
            return (top !== null && top !== undefined) ? top : ci
        }
        x: 0
        y: 0
        width: root.width
        height: root.height
        z: 1000
        // Capability gate: on a software scene graph the overlay is not
        // merely invisible — it never instantiates (the same no-node path as
        // all-off), however many effect prefs are set.  The saved prefs are
        // left untouched, so a hardware backend restores the tube exactly as
        // it was configured.
        active: root.effectsActive && ThemeEngine.effectsSupported
        sourceComponent: effectsOverlayComponent
    }

    // Global shortcuts: Search (Ctrl+F), Join channel (Ctrl+J), Settings.
    // Top-level Shortcut items — ToolButton/MenuItem have no shortcut prop.
    Shortcut {
        sequence: "Ctrl+F"
        enabled: root.pageStack.depth > 1
        onActivated: root.focusChatSearch()
    }

    Shortcut {
        sequence: "Ctrl+J"
        enabled: root.pageStack.depth > 1 && root.bridge.connection_state === 2
        onActivated: root.requestChatJoin()
    }

    Shortcut {
        sequence: StandardKey.Preferences
        onActivated: root.openSettings()
    }

    // ---------------------------------------------------------------------- //
    // Page stack
    // ---------------------------------------------------------------------- //
    pageStack.initialPage: ConnectPage {
        bridge: root.bridge
        kircConfig: root.appConfig
        hostWindow: root

        // The form's SASL mechanism choice flows here (same 0/1/2 mapping).
        onConnectRequested: (host, port, tls, nickname, saslUser, saslPass, saslMechanism, serverPass) => {
            // Remember what was attempted; persisted once the connection
            // actually succeeds (state 2 below). The SASL password is kept in
            // memory only (never KConfig): reused by tryReconnect and handed
            // to the tray through sessionSaslPassword so a tray reconnect
            // does not SASL-904-loop.  The server password follows the same
            // rule (memory + sessionServerPassword for the tray).
            root.lastHost = host
            root.lastPort = port
            root.lastTls = tls
            root.lastNickname = nickname
            root.lastSaslUser = saslUser
            root.lastSaslPass = saslPass
            root.lastServerPass = (serverPass === undefined || serverPass === null) ? "" : serverPass
            root.lastSaslMechanism = (saslMechanism === undefined) ? root.saslMechanism : saslMechanism
            root.saslMechanism = root.lastSaslMechanism
            if (root.appConfig !== null && root.appConfig.sessionSaslPassword !== undefined) {
                root.appConfig.sessionSaslPassword = saslPass
            }
            if (root.appConfig !== null && root.appConfig.sessionServerPassword !== undefined) {
                root.appConfig.sessionServerPassword = root.lastServerPass
            }
            root.userDisconnect = false
            root.lastDropWasAuthFailure = false
            root.lastConnectionError = ""
            root.reconnectAttempt = 0
            reconnectTimer.stop()

            root.applySaslMechanism()
            root.applyServerPassword()
            root.applyCtcpVersionReply()
            root.bridge.connect_server(host, port, tls, nickname, saslUser, saslPass)
            root.openChat()
        }
    }

    // ---------------------------------------------------------------------- //
    // Bridge signals handled at window level
    // ---------------------------------------------------------------------- //
    Connections {
        target: root.bridge

        function onState_changed(state) {
            if (state === 2) {
                root.reconnectAttempt = 0
                root.reconnectSeconds = 0
                root.lastConnectionError = ""
                root.lastDropWasAuthFailure = false
                reconnectTimer.stop()
                root.saveProfile()
                // A live session must not be stranded on the connection form
                // (the tray can connect without the UI ever pushing ChatPage).
                root.ensureChatVisible()
            } else if (state === 0) {
                if (!root.userDisconnect && root.wantReconnect() && root.lastHost.length > 0) {
                    // Never retry an authentication failure unless the user
                    // opted in: a bad password would otherwise 904-loop, and
                    // the tray honors the same policy (KircTray::onConnect is
                    // only reached from an explicit click).
                    if (root.lastDropWasAuthFailure && !root.reconnectAfterAuthFailureAllowed()) {
                        root.lastDropWasAuthFailure = false
                        if (root.pageStack.depth > 1) {
                            root.pageStack.pop()
                        }
                        return
                    }
                    var limit = root.reconnectLimit()
                    if (limit > 0 && root.reconnectAttempt >= limit) {
                        if (root.pageStack.depth > 1) {
                            root.pageStack.pop()
                        }
                        return
                    }
                    reconnectTimer.interval = Math.min(30000, 3000 * Math.pow(2, root.reconnectAttempt))
                    root.reconnectAttempt += 1
                    root.reconnectSeconds = Math.ceil(reconnectTimer.interval / 1000)
                    reconnectTimer.start()
                    return
                }
                if (root.pageStack.depth > 1) {
                    root.pageStack.pop()
                }
            }
        }

        function onNotification_fired(title, body) {
            // Native KNotification is the C++ side's job (cpp/kircnotify.cpp);
            // the in-app notice is gated here on the notification prefs.
            if (!root.notificationsAllowed(title)) {
                return
            }
            root.showPassiveNotification(title.length > 0 ? (title + " — " + body) : body)
        }

        function onError_occurred(message) {
            root.lastConnectionError = String(message)
            if (root.looksLikeAuthFailure(message)) {
                root.lastDropWasAuthFailure = true
            }
            root.showPassiveNotification(message, 5000)
        }

        // onInfo: intentional no handler — informational lines (MOTD,
        // numerics, joins/parts) are persisted to the *server* buffer in
        // the Rust bridge instead of transient popups.
    }

    // ---------------------------------------------------------------------- //
    // Helpers
    // ---------------------------------------------------------------------- //
    function openChat()
    {
        if (root.pageStack.depth > 1) {
            return
        }
        root.pageStack.push(Qt.resolvedUrl("ChatPage.qml"), {
            "bridge": root.bridge,
            "hostWindow": root,
            "currentChannel": root.chatChannel
        })
    }

    /// A live session must always be reachable from the current page — the
    /// chat page, or the settings pane (which pops back to it). Called on every
    /// transition to "connected", because a session can become live without
    /// the UI ever pushing ChatPage (the tray's connect path), and because a
    /// pop must never be able to strand one on the connection form.
    function ensureChatVisible()
    {
        if (root.pageStack.depth > 1) {
            // Chat or settings: both can reach the session.
            return
        }
        root.openChat()
    }

    function tryReconnect()
    {
        if (root.userDisconnect || root.lastHost.length === 0) {
            return
        }
        root.applySaslMechanism()
        root.applyServerPassword()
        root.applyCtcpVersionReply()
        root.bridge.connect_server(root.lastHost, root.lastPort, root.lastTls,
                                   root.lastNickname, root.lastSaslUser, root.lastSaslPass)
    }

    function wantReconnect()
    {
        return root.appConfig !== null && root.appConfig.reconnect
    }

    /// Max automatic reconnect attempts (0 = unlimited).  Defaults to 10 so
    /// a dead network cannot retry forever; harnesses without prefs behave
    /// as unlimited.
    function reconnectLimit()
    {
        if (root.appConfig !== null && root.appConfig.reconnectLimit !== undefined) {
            return root.appConfig.reconnectLimit
        }
        return 0
    }

    /// Whether an authentication-failure drop may be retried.  Off unless the
    /// user opts in, so a bad SASL/NickServ password never loops.
    function reconnectAfterAuthFailureAllowed()
    {
        if (root.appConfig !== null && root.appConfig.reconnectAfterAuthFailure !== undefined) {
            return root.appConfig.reconnectAfterAuthFailure
        }
        return false
    }

    /// True when `message` looks like a SASL/authentication failure (904-907,
    /// "authentication failed", NickServ "invalid password" / "not registered").
    function looksLikeAuthFailure(message)
    {
        if (message === undefined || message === null) {
            return false
        }
        var m = String(message).toLowerCase()
        return m.indexOf("904") >= 0 || m.indexOf("905") >= 0
            || m.indexOf("906") >= 0 || m.indexOf("907") >= 0
            || m.indexOf("sasl authentication failed") >= 0
            || m.indexOf("authentication failed") >= 0
            || m.indexOf("invalid password") >= 0
            || m.indexOf("password incorrect") >= 0
            || m.indexOf("not registered") >= 0
    }

    /// Gate for notification_fired: highlights need notifyHighlights, a
    /// private-message title (a nick, not a #channel) needs
    /// notifyDirectMessages.  Harnesses without prefs allow everything.
    function notificationsAllowed(title)
    {
        if (root.appConfig === null) {
            return true
        }
        var highlights = root.appConfig.notifyHighlights
        var directs = root.appConfig.notifyDirectMessages
        if (highlights === undefined && directs === undefined) {
            return true
        }
        var t = String(title === undefined || title === null ? "" : title)
        var isChannel = t.length > 0 && (t.charAt(0) === "#" || t.charAt(0) === "&"
                      || t.charAt(0) === "+" || t.charAt(0) === "!")
        if (isChannel) {
            return highlights === undefined ? true : highlights
        }
        // Private message (or untitled notice): both prefs apply.
        if (highlights !== undefined && !highlights) {
            return false
        }
        return directs === undefined ? true : directs
    }

    /// Push the persisted SASL mechanism into the bridge.  Must run BEFORE
    /// connect_server (bridge contract).  Guarded with typeof so harnesses
    /// whose stub predates set_sasl_mechanism keep working.
    function applySaslMechanism()
    {
        if (typeof root.bridge.set_sasl_mechanism !== "function") {
            return
        }
        root.bridge.set_sasl_mechanism(root.saslMechanism)
    }

    /// Hand the IRC PASS password to the bridge.  Must run BEFORE
    /// connect_server (same contract as set_sasl_mechanism).  Guarded with
    /// typeof so a harness/double that predates the invokable keeps working;
    /// an empty password is skipped entirely.  When the connect form left the
    /// field empty, fall back to the KWallet-backed value from the settings
    /// pane (that is how a password stored in Settings reaches the connect).
    function applyServerPassword()
    {
        if (typeof root.bridge.set_server_password !== "function") {
            return
        }
        var password = root.lastServerPass
        if ((password === undefined || password === null || password.length === 0)
                && root.appConfig !== null && root.appConfig.serverPassword !== undefined) {
            password = String(root.appConfig.serverPassword)
        }
        if (password.length === 0) {
            return
        }
        root.bridge.set_server_password(password)
    }

    /// The persisted "reply to CTCP VERSION" preference (default on).
    /// Harnesses without prefs behave like the bridge default.
    function respondToCtcpVersion()
    {
        if (root.appConfig !== null && root.appConfig.respondToCtcpVersion !== undefined) {
            return root.appConfig.respondToCtcpVersion
        }
        return true
    }

    /// Hand the CTCP VERSION auto-reply choice to the bridge.  Must run BEFORE
    /// connect_server (same contract as set_sasl_mechanism) and on EVERY
    /// connect path, reconnects included: the bridge keeps the value for the
    /// session, so a dropped connection that is retried without this call
    /// would silently fall back to the default and start advertising the
    /// client again.  Guarded with typeof so older doubles keep working.
    function applyCtcpVersionReply()
    {
        if (typeof root.bridge.set_ctcp_version_reply !== "function") {
            return
        }
        root.bridge.set_ctcp_version_reply(root.respondToCtcpVersion())
    }

    /// Open the chat page's join dialog when it exists; otherwise drive the
    /// chat page's own join entry (both owned by ChatPage, guarded by
    /// typeof so harnesses without them keep working).
    // qmllint disable missing-property
    function requestChatJoin()
    {
        var page = root.pageStack.currentItem
        if (page) {
            if (typeof page["openJoinDialog"] === "function") {
                page["openJoinDialog"]()
                return
            }
            // Older ChatPage without the dialog: drive its join entry when
            // present (it sends JOIN via the bridge itself).
            if (typeof page["tryJoin"] === "function") {
                page["tryJoin"]()
                return
            }
        }
    }
    // qmllint enable missing-property

    /// Give the chat page's search field focus (Ctrl+F toolbar action).
    /// No-op when no chat page is open or it has no search UI.
    // qmllint disable missing-property
    function focusChatSearch()
    {
        var page = root.pageStack.currentItem
        if (page && typeof page["focusSearch"] === "function") {
            page["focusSearch"]()
        }
    }
    // qmllint enable missing-property

    /// Menu > Help (p9): print the command reference into the active buffer,
    /// exactly as `/help` does.  That is where `/join` and the rest of the
    /// commands stay discoverable now that the header has no [join] control.
    // qmllint disable missing-property
    function openHelp()
    {
        var page = root.pageStack.currentItem
        if (page && typeof page["showHelp"] === "function") {
            page["showHelp"]()
            return
        }
        // Older ChatPage without the hook: the dispatcher is the same code
        // path /help takes.
        if (page && typeof page["runSlash"] === "function") {
            page["runSlash"]("/help")
        }
    }
    // qmllint enable missing-property

    /// Push the settings pane (single instance: pop back to it if open).
    function openSettings()
    {
        for (var i = 0; i < root.pageStack.depth; ++i) {
            var item = root.pageStack.get(i)
            if (item && item.isKircSettingsPage) {
                while (root.pageStack.depth - 1 > i) {
                    root.pageStack.pop()
                }
                return
            }
        }
        root.pageStack.push(Qt.resolvedUrl("SettingsPage.qml"), {
            "kircConfig": root.appConfig,
            "hostWindow": root
        })
    }

    /// Menu > Effects > "Effects settings…" (p10): open the settings pane on
    /// its Effects section, where the intensities live.  The pane resolves the
    /// section itself (showEffects), so this file never hardcodes an index; the
    /// selectSection(3) fallback only serves a pane that predates showEffects.
    // qmllint disable missing-property
    function openEffectsSettings()
    {
        root.openSettings()
        var page = root.pageStack.currentItem
        if (page && typeof page["showEffects"] === "function") {
            page["showEffects"]()
            return
        }
        if (page && typeof page["selectSection"] === "function") {
            page["selectSection"](3)
        }
    }
    // qmllint enable missing-property

    /// The About content lives in the settings pane's About section.
    // qmllint disable missing-property
    function openAbout()
    {
        root.openSettings()
        var page = root.pageStack.currentItem
        if (page && typeof page["showAbout"] === "function") {
            page["showAbout"]()
        }
    }
    // qmllint enable missing-property

    function closeCurrentBuffer()
    {
        var page = root.pageStack.currentItem
        // qmllint disable missing-property
        if (page && page["closeBuffer"]) {
            page["closeBuffer"](root.chatChannel)
        }
        // qmllint enable missing-property
    }

    /// Persist the profile that just connected. host/port/tls/nickname and the
    /// SASL *username* only — never a password (kirc.conf is plaintext).
    function saveProfile()
    {
        if (root.appConfig === null || root.lastHost.length === 0) {
            return
        }
        root.appConfig.host = root.lastHost
        root.appConfig.port = root.lastPort
        root.appConfig.tls = root.lastTls
        root.appConfig.nickname = root.lastNickname
        root.appConfig.saslUser = root.lastSaslUser
        root.appConfig.save()
    }
}
