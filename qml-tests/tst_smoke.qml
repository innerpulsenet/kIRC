// Runtime smoke harness for the kIRC QML UI.
// Loads main.qml (with the stub IrcBridge/MessageListModel from this module),
// drives a connect -> chat -> theme-switch flow and reports PASS/FAIL.
// Uses console.error because console.log is filtered by the qml runtime here.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: harness
    width: 1024
    height: 700

    property int step: 0
    property int failures: 0
    property var win: mainLoader.item

    function ok(name, cond, extra) {
        if (cond) {
            console.error("PASS " + name + (extra !== undefined ? " :: " + extra : ""))
        } else {
            harness.failures++
            console.error("FAIL " + name + (extra !== undefined ? " :: " + extra : ""))
        }
    }

    Loader {
        id: mainLoader
        source: Qt.resolvedUrl("org/kde/kirc/main.qml")
        onStatusChanged: {
            if (status === Loader.Error) {
                harness.failures++
                console.error("FAIL main.qml load: " + sourceComponent)
            }
        }
    }

    Loader {
        id: connectLoader
        source: Qt.resolvedUrl("org/kde/kirc/ConnectPage.qml")
        onStatusChanged: if (status === Loader.Error) { harness.failures++; console.error("FAIL ConnectPage.qml load") }
    }

    Loader {
        id: chatLoader
        source: Qt.resolvedUrl("org/kde/kirc/ChatPage.qml")
        onStatusChanged: if (status === Loader.Error) { harness.failures++; console.error("FAIL ChatPage.qml load") }
    }

    // Settings pane, standalone, with its own config double, created with
    // `kircConfig` as an INITIAL property (the same order as the app's
    // pageStack.push, so Component.onCompleted sees the config).  Seeded with
    // respondToCtcpVersion OFF so the page must show that value and persist a
    // change back — the settings half of the CTCP VERSION contract.
    property var settingsPageItem: null
    Component.onCompleted: {
        // Capability pin (the harness double for ThemeEngine's runtime probe):
        // the offscreen platform renders Qt Quick with the SOFTWARE renderer,
        // so main.qml's GraphicsInfo probe would report the effects
        // unsupported and every assertion below about the effects popup and
        // the overlay would describe a UI this harness is not testing.  Pin
        // the capability ON (the Linux/CI semantics this file was written
        // for); the dedicated degradation block further down releases the pin
        // to assert the software path, then restores it.
        ThemeEngine._effectsForceSupported = true
        var comp = Qt.createComponent("org/kde/kirc/SettingsPage.qml")
        if (comp.status === Component.Ready) {
            harness.settingsPageItem = comp.createObject(harness, { "kircConfig": settingsCfg })
            if (harness.settingsPageItem === null) {
                harness.failures++
                console.error("FAIL SettingsPage.qml createObject")
            }
        } else {
            harness.failures++
            console.error("FAIL SettingsPage.qml load: " + comp.errorString())
        }
    }

    QtObject {
        id: settingsCfg
        property string themeId: "tui"
        property int fontDelta: 0
        property string fontFamily: ""
        property string autojoin: ""
        property bool reconnect: true
        property bool minimizeToTray: true
        property bool identifyOnConnect: false
        property string nickservNick: ""
        property string nickservPassword: ""
        property int saslMechanism: 0
        property bool notifyHighlights: true
        property bool notifyDirectMessages: true
        property int reconnectLimit: 10
        property bool reconnectAfterAuthFailure: false
        property int historyLimit: 200
        property string defaultPartReason: "Leaving"
        property string serverPassword: ""
        property bool showTimestamps: true
        property string nickname: "kircuser"
        // The pref under test, seeded OFF.
        property bool respondToCtcpVersion: false
        // ---- CRT effect prefs (p10) ------------------------------------
        // The same [UI] keys KircConfig exposes, so the pane's Effects
        // section has a real contract to bind to (all OFF by default, like
        // the C++ defaults).
        property bool scanlines: false
        property int scanlineAmount: 35
        property bool vignette: false
        property int vignetteAmount: 30
        property bool grain: false
        property int grainAmount: 10
        property bool flicker: false
        property int flickerAmount: 4
        property bool humBar: false
        property int humBarAmount: 8
        property bool reflection: false
        property int reflectionAmount: 25
        property bool saved: false
        function save() { settingsCfg.saved = true }
    }

    // ---- theme engine unit checks (independent of the UI) ------------------
    QtObject {
        id: themeTests
        Component.onCompleted: {
            var out = ""

            // built-ins: the default is the dense terminal look (schema 3)
            out = ThemeEngine.applyBuiltinTheme("tui")
            harness.ok("applyBuiltinTheme(tui) is the dense default",
                       out === "" && ThemeEngine.themeId === "tui"
                       && ThemeEngine.themeName === "TUI" && ThemeEngine.mode === "dense",
                       "mode=" + ThemeEngine.mode)
            harness.ok("tui terminal tokens are real",
                       ThemeEngine.fontFamily.length > 0
                       && ThemeEngine.gutterWidth > 0
                       && ThemeEngine.nickColumn > 0
                       && ThemeEngine.ruleColor.length > 0
                       && String(ThemeEngine.fgPrimary).length > 0
                       && String(ThemeEngine.fgDim).length > 0
                       && String(ThemeEngine.fgAccent).length > 0
                       && String(ThemeEngine.fgWarn).length > 0
                       && String(ThemeEngine.bgPanel).length > 0
                       && String(ThemeEngine.bgLog).length > 0
                       && String(ThemeEngine.bgInput).length > 0,
                       "font=" + ThemeEngine.fontFamily + " gutter=" + ThemeEngine.gutterWidth
                       + " nickCol=" + ThemeEngine.nickColumn)
            harness.ok("tui is flat (no bubbles, no avatars)",
                       ThemeEngine.bubbleRadius === 0 && ThemeEngine.avatarEnabled === false
                       && ThemeEngine.shadowOpacity === 0,
                       "r=" + ThemeEngine.bubbleRadius + " avatar=" + ThemeEngine.avatarEnabled)

            // every built-in theme is a dense terminal palette
            var allDense = ThemeEngine.availableThemeIds.length >= 5
            var denseNames = []
            for (var t = 0; t < ThemeEngine.availableThemeIds.length; ++t) {
                out = ThemeEngine.applyBuiltinTheme(ThemeEngine.availableThemeIds[t])
                if (out !== "" || ThemeEngine.mode !== "dense") { allDense = false }
                denseNames.push(ThemeEngine.themeId)
            }
            harness.ok("every built-in theme is dense", allDense, denseNames.join(","))
            harness.ok("mode is never bubble", ThemeEngine.mode !== "bubble")

            // retired bubble/glass ids resolve to the TUI default at runtime
            // (the C++ schema-3 migration rewrites them on disk)
            out = ThemeEngine.applyBuiltinTheme("oxygen")
            harness.ok("retired id oxygen resolves to tui",
                       out === "" && ThemeEngine.themeId === "tui", "id=" + ThemeEngine.themeId)
            out = ThemeEngine.applyBuiltinTheme("neon")
            harness.ok("retired id neon resolves to tui",
                       out === "" && ThemeEngine.themeId === "tui", "id=" + ThemeEngine.themeId)
            out = ThemeEngine.applyBuiltinTheme("fluent-light")
            harness.ok("retired id fluent-light resolves to tui",
                       out === "" && ThemeEngine.themeId === "tui", "id=" + ThemeEngine.themeId)
            harness.ok("isRetiredThemeId",
                       ThemeEngine.isRetiredThemeId("breeze-classic")
                       && !ThemeEngine.isRetiredThemeId("tui")
                       && !ThemeEngine.isRetiredThemeId("my-own-theme"))

            // the legacy id of the pre-modernisation default still resolves
            out = ThemeEngine.applyBuiltinTheme("breeze-dark-default")
            harness.ok("legacy theme id alias", out === "" && ThemeEngine.themeId === "breeze",
                       "id=" + ThemeEngine.themeId)

            // the other terminal palettes are loadable
            out = ThemeEngine.applyBuiltinTheme("phosphor")
            harness.ok("applyBuiltinTheme(phosphor)",
                       out === "" && ThemeEngine.mode === "dense"
                       && ThemeEngine.themeName === "Phosphor", "mode=" + ThemeEngine.mode)
            out = ThemeEngine.applyBuiltinTheme("amber")
            harness.ok("applyBuiltinTheme(amber)", out === "" && ThemeEngine.mode === "dense"
                       && ThemeEngine.themeName === "Amber")
            out = ThemeEngine.applyBuiltinTheme("ice")
            harness.ok("applyBuiltinTheme(ice)", out === "" && ThemeEngine.mode === "dense"
                       && ThemeEngine.themeName === "Ice")

            // breeze is a dense palette that follows the desktop colours
            out = ThemeEngine.applyBuiltinTheme("breeze")
            harness.ok("applyBuiltinTheme(breeze) is a dense palette",
                       out === "" && ThemeEngine.mode === "dense" && ThemeEngine.bubbleRadius === 0
                       && ThemeEngine.surface === "" && ThemeEngine.fgPrimary === "",
                       "mode=" + ThemeEngine.mode)

            out = ThemeEngine.applyBuiltinTheme("nope")
            harness.ok("applyBuiltinTheme(unknown) reports error", out !== "" && ThemeEngine.configError !== "")

            // ---- schema 4: per-kind message tokens -------------------------
            // The engine exposes the token-set schema; every theme declares
            // it; a stored config naming any built-in (or retired) id must
            // resolve to a theme that carries the whole set.
            out = ThemeEngine.applyBuiltinTheme("tui")
            harness.ok("theme token schema is version 4",
                       out === "" && ThemeEngine.themeSchemaVersion === 4
                       && ThemeEngine.themeSchema === 4,
                       "schema=" + ThemeEngine.themeSchema + " version=" + ThemeEngine.themeSchemaVersion)
            var pk = [ThemeEngine.fgEvent, ThemeEngine.fgMessage, ThemeEngine.fgPrivate,
                      ThemeEngine.fgNotice, ThemeEngine.fgAction, ThemeEngine.fgHighlight,
                      ThemeEngine.fgWarn]
            var pkSeen = {}, pkOk = true
            for (var pi = 0; pi < pk.length; ++pi) {
                if (String(pk[pi]).length === 0 || pkSeen[pk[pi]] === true) { pkOk = false }
                pkSeen[pk[pi]] = true
            }
            harness.ok("tui per-kind tokens are all set and pairwise distinct", pkOk, pk.join(","))
            harness.ok("per-kind resolvers honour the theme token",
                       ThemeEngine.fgNoticeColor("#fb") === ThemeEngine.fgNotice
                       && ThemeEngine.fgActionColor("#fb") === ThemeEngine.fgAction
                       && ThemeEngine.fgEventColor("#fb") === ThemeEngine.fgEvent
                       && ThemeEngine.fgHighlightColor("#fb") === ThemeEngine.fgHighlight)

            // the retro/BBS set (schema 4 additions): every one must load and
            // must define every per-kind token (fixed palettes)
            var retro = ["bbs", "c64", "vt", "ega", "synthwave"]
            var retroNames = [], retroOk = true
            for (var ri = 0; ri < retro.length; ++ri) {
                out = ThemeEngine.applyBuiltinTheme(retro[ri])
                if (out !== "" || ThemeEngine.themeSchema !== 4) { retroOk = false }
                var rk = [ThemeEngine.fgEvent, ThemeEngine.fgMessage, ThemeEngine.fgPrivate,
                          ThemeEngine.fgNotice, ThemeEngine.fgAction, ThemeEngine.fgHighlight,
                          ThemeEngine.fgWarn]
                for (var rj = 0; rj < rk.length; ++rj) {
                    if (String(rk[rj]).length === 0) { retroOk = false }
                }
                retroNames.push(ThemeEngine.themeId + "=" + ThemeEngine.themeName)
            }
            harness.ok("the retro/BBS themes load with every per-kind token set", retroOk,
                       retroNames.join(", "))

            // breeze is palette-driven: the per-kind tokens are DEFINED but
            // empty, and the resolver must fall back to the caller's colour.
            out = ThemeEngine.applyBuiltinTheme("breeze")
            harness.ok("breeze defines the per-kind tokens as empty (desktop palette)",
                       out === "" && ThemeEngine.fgEvent === "" && ThemeEngine.fgMessage === ""
                       && ThemeEngine.fgPrivate === "" && ThemeEngine.fgNotice === ""
                       && ThemeEngine.fgAction === "" && ThemeEngine.fgHighlight === ""
                       && ThemeEngine.fgSelf === "")
            harness.ok("an empty per-kind token falls back to the caller's colour",
                       ThemeEngine.fgNoticeColor("#fallback") === "#fallback"
                       && ThemeEngine.fgEventColor("#fallback") === "#fallback")

            // every id a stored kirc.conf can name — built-ins, the legacy
            // alias and the retired bubble/glass ids — must resolve to a
            // schema-4 theme (the v2->v3 strand, where a user sat on Oxygen,
            // must not be reachable again).
            var storedIds = ["tui", "phosphor", "amber", "ice", "breeze",
                             "bbs", "c64", "vt", "ega", "synthwave",
                             "breeze-dark-default", "oxygen", "neon", "fluent",
                             "fluent-light", "breeze-classic"]
            var reachOk = true, reachBad = []
            for (var si = 0; si < storedIds.length; ++si) {
                out = ThemeEngine.applyBuiltinTheme(storedIds[si])
                if (out !== "" || ThemeEngine.themeSchema !== 4
                        || ThemeEngine.fgNotice === undefined) {
                    reachOk = false
                    reachBad.push(storedIds[si])
                }
            }
            harness.ok("every stored/retired theme id resolves to a schema-4 theme",
                       reachOk, reachBad.join(","))
            // The theme list is additive — new palettes land in it (p10 added
            // crt/paper/gruvbox) — so the exact total is not pinned; every
            // built-in must simply be offered.  Name each one: a palette that
            // silently vanished from BUILTIN_IDS would keep the count above the
            // floor, so the floor alone proves nothing.  (14 built-ins once the
            // p10 trio lands: the 11 below plus crt, paper and gruvbox.)
            harness.ok("the theme list offers every built-in",
                       ThemeEngine.availableThemeIds.length >= 14
                       && ["tui", "phosphor", "amber", "ice", "breeze", "bbs", "c64", "vt",
                           "ega", "synthwave", "ai-slop",
                           "crt", "paper", "gruvbox"].every(function (id) {
                               return ThemeEngine.availableThemeIds.indexOf(id) >= 0
                           }),
                       "ids=" + ThemeEngine.availableThemeIds.join(","))

            // back to the default for the UI part of the test
            ThemeEngine.applyBuiltinTheme("tui")

            // bad JSON must not clobber the active theme
            out = ThemeEngine.applyThemeJson("{ not json")
            harness.ok("applyThemeJson(bad) reports error",
                       out !== "" && ThemeEngine.mode === "dense" && ThemeEngine.themeId === "tui")

            // partial JSON is merged over the terminal defaults
            out = ThemeEngine.applyThemeJson(JSON.parse('{"id":"custom","name":"Custom","fonts":{"messageSize":11},"terminal":{"fgPrimary":"#ff00ff"}}'))
            harness.ok("applyThemeJson(partial) merges defaults",
                       out === "" && ThemeEngine.mode === "dense" && ThemeEngine.messageSize === 11
                       && String(ThemeEngine.fgPrimary) === "#ff00ff"
                       && ThemeEngine.nickLightnessDark === 0.70 && ThemeEngine.bubbleRadius === 0,
                       "fg=" + ThemeEngine.fgPrimary + " l=" + ThemeEngine.nickLightnessDark)

            // an old bubble-schema theme file still loads (missing keys never
            // break loading) and is coerced to the dense layout
            out = ThemeEngine.applyThemeJson('{"name":"Old Bubble","mode":"bubble","bubble":{"radius":12},"avatar":{"enabled":true}}')
            harness.ok("old bubble JSON loads as dense",
                       out === "" && ThemeEngine.themeName === "Old Bubble"
                       && ThemeEngine.mode === "dense" && ThemeEngine.bubbleRadius === 12
                       && ThemeEngine.fontFamily.length > 0,
                       "mode=" + ThemeEngine.mode)

            out = ThemeEngine.applyThemeJson('{"name":"From String","mode":"bubble"}')
            harness.ok("applyThemeJson(JSON string)",
                       out === "" && ThemeEngine.themeName === "From String" && ThemeEngine.mode === "dense")

            // out-of-range knobs are clamped instead of breaking the view
            out = ThemeEngine.applyThemeJson('{"bubble":{"maxWidthFraction":42,"radius":-5},"grouping":{"windowMinutes":99999},"terminal":{"nickColumn":999,"gutterWidth":99999}}')
            harness.ok("theme knobs are clamped",
                       out === "" && ThemeEngine.bubbleMaxWidthFraction === 1.0
                       && ThemeEngine.bubbleRadius === 0 && ThemeEngine.groupingWindowMinutes === 1440
                       && ThemeEngine.nickColumn === 64 && ThemeEngine.gutterWidth === 512,
                       "f=" + ThemeEngine.bubbleMaxWidthFraction + " r=" + ThemeEngine.bubbleRadius
                       + " w=" + ThemeEngine.groupingWindowMinutes + " nickCol=" + ThemeEngine.nickColumn)

            // the settings font-family override wins over the theme's own family
            ThemeEngine.applyBuiltinTheme("tui")
            var themeFamily = ThemeEngine.fontFamily
            ThemeEngine.fontFamilyOverride = "Fira Code"
            harness.ok("font family override wins",
                       ThemeEngine.fontFamily === "Fira Code" && ThemeEngine.fontFamilyIsCustom === true,
                       ThemeEngine.fontFamily)
            harness.ok("monospace families offered", ThemeEngine.monospaceFamilies().length >= 5)
            ThemeEngine.fontFamilyOverride = ""
            harness.ok("font family falls back to the theme",
                       ThemeEngine.fontFamily === themeFamily && ThemeEngine.fontFamilyIsCustom === false,
                       ThemeEngine.fontFamily)

            // nick padding for the message log's nick column
            harness.ok("paddedNick pads to the nick column",
                       ThemeEngine.paddedNick("bob").length === ThemeEngine.nickColumn
                       && ThemeEngine.paddedNick("averyveryverylongnick") === "averyveryverylongnick"
                       && ThemeEngine.paddedNick("bob") !== "bob",
                       "\"" + ThemeEngine.paddedNick("bob") + "\"")


            // nick colours: deterministic, in range, distinct, dark/light aware
            var c1 = ThemeEngine.nickColor("alice", true)
            var c2 = ThemeEngine.nickColor("alice", true)
            harness.ok("nickColor deterministic", c1 === c2, c1.toString())
            harness.ok("nickColor in range", c1.r >= 0 && c1.r <= 1 && c1.a > 0.9)
            var names = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi"]
            var seen = {}, distinct = 0
            for (var i = 0; i < names.length; ++i) {
                var k = ThemeEngine.nickColor(names[i], true).toString()
                if (!seen[k]) { seen[k] = 1; distinct++ }
            }
            harness.ok("nickColor distinct for 8 nicks", distinct === 8, "distinct=" + distinct)
            harness.ok("nickColor dark != light", ThemeEngine.nickColor("alice", true) !== ThemeEngine.nickColor("alice", false))

            // avatar helpers
            harness.ok("initial(nick)", ThemeEngine.initial("alice") === "A"
                       && ThemeEngine.initial("_bob") === "B" && ThemeEngine.initial("") === "?",
                       ThemeEngine.initial("alice") + ThemeEngine.initial("_bob") + ThemeEngine.initial(""))
            harness.ok("contrastingTextColor", ThemeEngine.contrastingTextColor("#000000") === "#ffffff"
                       && ThemeEngine.contrastingTextColor("#ffffff") !== "#ffffff")
            harness.ok("avatar/sidebar sizes scale with the grid",
                       ThemeEngine.avatarSizeFor(18) > 0 && ThemeEngine.sidebarWidthFor(18) > 0)

            // hashing
            harness.ok("hashNick stable", ThemeEngine.hashNick("Alice") === ThemeEngine.hashNick("alice"))

            // message grouping window (back on the default theme)
            ThemeEngine.applyBuiltinTheme("breeze")
            harness.ok("default grouping window", ThemeEngine.groupingWindowMinutes === 5,
                       "win=" + ThemeEngine.groupingWindowMinutes)
            var rowA = {"nick": "alice", "timestamp": "09:00", "isSelf": false}
            harness.ok("grouped: 4 minutes apart", ThemeEngine.grouped(rowA, {"nick": "alice", "timestamp": "09:04", "isSelf": false}) === true)
            harness.ok("grouped: 6 minutes apart", ThemeEngine.grouped(rowA, {"nick": "alice", "timestamp": "09:06", "isSelf": false}) === false)
            harness.ok("grouped: different nick", ThemeEngine.grouped(rowA, {"nick": "bob", "timestamp": "09:01", "isSelf": false}) === false)
            harness.ok("grouped: nick case-insensitive", ThemeEngine.grouped(rowA, {"nick": "ALICE", "timestamp": "09:01", "isSelf": false}) === true)
            harness.ok("grouped: self vs other is a break",
                       ThemeEngine.grouped({"nick": "alice", "timestamp": "09:00", "isSelf": true}, rowA) === false)
            harness.ok("grouped: unparseable timestamp is a break",
                       ThemeEngine.grouped(rowA, {"nick": "alice", "timestamp": "", "isSelf": false}) === false)
            harness.ok("grouped: day rollover is a break",
                       ThemeEngine.grouped({"nick": "alice", "timestamp": "23:59", "isSelf": false},
                                           {"nick": "alice", "timestamp": "00:01", "isSelf": false}) === false)
            harness.ok("parseTimestamp", ThemeEngine.parseTimestamp("12:34") === 754
                       && ThemeEngine.parseTimestamp("12:34:56") === 754
                       && ThemeEngine.parseTimestamp("nope") === -1)

            // escaping / linkify (never renders injected markup)
            var f = ThemeEngine.formatMessage("<b>bold</b> see https://kde.org now")
            harness.ok("formatMessage escapes html", f.indexOf("&lt;b&gt;") === 0, f)
            harness.ok("formatMessage linkifies", f.indexOf("<a href=\"https://kde.org\">https://kde.org</a>") > 0, f)
            var fl = ThemeEngine.formatMessage("see https://kde.org", "#ff8800")
            harness.ok("formatMessage tints links", fl.indexOf("style=\"color:#ff8800\"") > 0, fl)
            harness.ok("cssColor", ThemeEngine.cssColor("#3daee9") === "#3daee9"
                       && ThemeEngine.cssColor("#abc") === "#aabbcc" && ThemeEngine.cssColor("") === "",
                       ThemeEngine.cssColor("#3daee9"))

            // luminance / dark detection
            harness.ok("luminance black", ThemeEngine.isDark("#000000"))
            harness.ok("luminance white", !ThemeEngine.isDark("#ffffff"))

            ThemeEngine.applyBuiltinTheme("breeze")
        }
    }

    Timer {
        id: driver
        interval: 250
        repeat: true
        running: true
        onTriggered: {
            ++harness.step
            switch (harness.step) {
            case 1:
                harness.ok("main.qml instantiated", mainLoader.status === Loader.Ready)
                harness.ok("ConnectPage instantiated standalone", connectLoader.status === Loader.Ready)
                harness.ok("ChatPage instantiated standalone (bridge null)", chatLoader.status === Loader.Ready)
                if (connectLoader.item) {
                    connectLoader.item.host = "   "
                    connectLoader.item.nickname = "   "
                    harness.ok("whitespace-only host and nickname are invalid",
                               connectLoader.item.formValid === false)
                }
                if (chatLoader.item) {
                    var sidebar = chatLoader.item
                    sidebar.channels = ["*server*", "NickServ", "#pain", "arm1-bot",
                                        "ChanServ", "#other", "mario-bot"]
                    var targets = sidebar.buffers.map(function(row) { return row.target }).join("|")
                    var sections = sidebar.buffers.filter(function(row) { return row.sectionStart })
                                                  .map(function(row) { return row.sectionTitle }).join("|")
                    harness.ok("sidebar groups each buffer kind into one section",
                               targets === "*server*|NickServ|ChanServ|#pain|#other|arm1-bot|mario-bot",
                               targets)
                    harness.ok("NickServ and ChanServ are labelled as Services",
                               sections === "Server|Services|Channels|Messages", sections)
                    sidebar.channels = ["*server*"]
                }
                if (harness.win) {
                    harness.ok("initialPage is the connection form", harness.win.pageStack.depth === 1)
                    harness.ok("bridge exposed on window", harness.win.bridge !== null && harness.win.bridge.connection_state === 0)
                    harness.ok("header shows Disconnected", harness.win.statusText === "Disconnected", harness.win.statusText)
                }
                break
            case 2:
                if (!harness.win) { break }
                var cp = harness.win.pageStack.initialPage
                cp.host = "  irc.test.example  "
                cp.nickname = "  smoketester  "
                cp.port = "6697"
                harness.ok("ConnectPage form valid after filling", cp.formValid === true)
                cp.tryConnect()
                break
            case 3: {
                if (!harness.win) { break }
                harness.ok("connect pushed the chat page", harness.win.pageStack.depth === 2, "depth=" + harness.win.pageStack.depth)
                harness.ok("state = connected", harness.win.bridge.connection_state === 2)
                harness.ok("header shows Connected", harness.win.statusText === "Connected", harness.win.statusText)
                var connectCall = harness.win.bridge.calls.filter(function(call) {
                    return call.fn === "connect_server"
                })[0]
                harness.ok("connect trims host and nickname",
                           connectCall !== undefined
                           && connectCall.args[0] === "irc.test.example"
                           && connectCall.args[3] === "smoketester",
                           connectCall === undefined ? "missing call" : connectCall.args.join("|"))
                // The CTCP VERSION auto-reply choice must reach the bridge
                // BEFORE connect_server (the double records every call, so the
                // order is asserted, not eyeballed).
                harness.ok("connect passes respondToCtcpVersion before connect_server",
                           harness.callIndex("set_ctcp_version_reply") >= 0
                           && harness.callIndex("set_ctcp_version_reply") < harness.callIndex("connect_server"),
                           "ctcp=" + harness.callIndex("set_ctcp_version_reply")
                           + " connect=" + harness.callIndex("connect_server"))
                harness.ok("the value applied matches the persisted pref default (on)",
                           harness.win.bridge.ctcp_version_reply === true,
                           "ctcp_version_reply=" + harness.win.bridge.ctcp_version_reply)
                // Reconnect path: a drop must not silently revert to the
                // bridge default.  tryReconnect() is driven directly — the
                // automatic path needs a real appConfig for the reconnect pref.
                harness.win.bridge.clearCalls()
                harness.win.tryReconnect()
                harness.ok("reconnect passes respondToCtcpVersion before connect_server",
                           harness.callIndex("set_ctcp_version_reply") >= 0
                           && harness.callIndex("set_ctcp_version_reply") < harness.callIndex("connect_server"),
                           "trace=[" + harness.win.bridge.callTrace() + "]")
                harness.win.bridge.clearCalls()
                break
            }
            case 4:
                // delegates must have been created from the model roles
                if (!harness.win) { break }
                var chat = harness.win.pageStack.currentIndex === 1
                        ? harness.win.pageStack.get(1) : null
                if (chat === null) { harness.failures++; console.error("FAIL chat page lookup"); break }
                var view = harness.findMessageView(chat, 0)
                harness.ok("message ListView exists", view !== null)
                if (view) {
                    // The double's canned transcript and the live appends race
                    // with this step, so assert "the seeded history rendered"
                    // rather than pinning an exact row count (the snapshot is
                    // not this test's contract; roles are, below).
                    harness.ok("seeded transcript rendered", view.count >= 4, "count=" + view.count)
                    var item = view.itemAtIndex(0)
                    harness.ok("delegate created from roles", item !== null && item.nick === "alice" && item.text !== undefined,
                               item ? ("nick=" + item.nick + " ts=" + item.timestamp) : "null")
                    harness.ok("delegate renders the dense layout", item !== null
                               && (item.styleMode === undefined || item.styleMode === 0),
                               item ? ("styleMode=" + item.styleMode) : "null")
                    var hl = view.itemAtIndex(3)
                    harness.ok("highlight role mapped", hl !== null && hl.isHighlight === true)
                    var own = view.itemAtIndex(2)
                    harness.ok("isSelf role mapped", own !== null && own.isSelf === true)
                    // Grouping (hiding a repeated sender) was a messenger idea
                    // and went away with the bubbles: every row is its own line
                    // and there is no avatar column in the dense layout.
                    var second = view.itemAtIndex(1)
                    harness.ok("no avatar column in the dense layout",
                               item !== null && second !== null && item.avatarVisible !== true
                               && second.avatarVisible !== true,
                               "avatars are gone with the bubbles")

                    // ---- per-kind rows (theme schema 4) ---------------------
                    // The canned snapshot carries a NOTICE, a /me and a query
                    // row; each must render with its own marker and take its
                    // own theme colour.  Assert under a fixed palette (tui) so
                    // the expected colours are deterministic.
                    var kindTheme = ThemeEngine.applyBuiltinTheme("tui")
                    var nRow = null, aRow = null, qRow = null
                    for (var ki = 0; ki < view.count; ++ki) {
                        var kt = view.itemAtIndex(ki)
                        if (kt === null) { continue }
                        if (String(kt.text).indexOf("psst") === 0) { nRow = kt }
                        if (String(kt.text).indexOf("does a little dance") >= 0) { aRow = kt }
                        if (String(kt.text).indexOf("query buffer") >= 0) { qRow = kt }
                    }
                    harness.ok("NOTICE row carries the notice role and marker",
                               kindTheme === "" && nRow !== null && nRow.isNotice === true
                               && nRow.isEvent === false
                               && String(nRow.bodyText).indexOf("- ") === 0,
                               nRow === null ? "null" : ("body=[" + nRow.bodyText + "]"))
                    harness.ok("NOTICE row takes the notice colour (body and nick)",
                               nRow !== null && nRow.bodyColor === nRow.fgNoticeColor
                               && nRow.bodyColor !== nRow.fgMessageColor
                               && nRow.nickColor === nRow.fgNoticeColor,
                               nRow === null ? "null" : ("body=" + nRow.bodyColor
                                                         + " msg=" + nRow.fgMessageColor))
                    harness.ok("/me action row takes the action colour",
                               aRow !== null && aRow.isAction === true
                               && aRow.bodyColor === aRow.fgActionColor
                               && aRow.bodyColor !== aRow.fgMessageColor,
                               aRow === null ? "null" : ("body=" + aRow.bodyColor
                                                         + " act=" + aRow.fgActionColor))
                    harness.ok("query row takes the private colour",
                               qRow !== null && qRow.isPrivate === true
                               && qRow.bodyColor === qRow.fgPrivateColor
                               && qRow.bodyColor !== qRow.fgMessageColor,
                               qRow === null ? "null" : ("body=" + qRow.bodyColor
                                                         + " priv=" + qRow.fgPrivateColor))
                    harness.ok("the per-kind rows render distinct colours",
                               nRow !== null && aRow !== null && qRow !== null
                               && nRow.bodyColor !== aRow.bodyColor
                               && aRow.bodyColor !== qRow.bodyColor
                               && nRow.bodyColor !== qRow.bodyColor)
                }
                break
            case 5: {
                // A CTCP request and a CTCP VERSION reply, seeded exactly as
                // the core writes them: an event row (nick "*") whose text
                // names the kind and the sender.
                if (!harness.win) { break }
                var ctcpView = harness.findMessageView(harness.win.pageStack.get(1), 0)
                if (ctcpView === null) { harness.failures++; console.error("FAIL CTCP seed: no view"); break }
                ctcpView.model.append_message("#kirc", "*", "CTCP VERSION request from alice", "12:08", false, false)
                ctcpView.model.append_message("#kirc", "*", "CTCP VERSION reply from bob: irssi 1.4.5 (20240101)", "12:09", false, false)
                ctcpView.positionViewAtEnd()
                break
            }
            case 6: {
                // A CTCP line must read as a dim system line and never as
                // ordinary chat: it takes the event path (no nick column, "* "
                // marker, dim colour) with the remote client's string visible,
                // and the row carries no hover state that could reflow it.
                if (!harness.win) { break }
                var v = harness.findMessageView(harness.win.pageStack.get(1), 0)
                if (v === null) { break }
                var req = v.itemAtIndex(v.count - 2)
                var rep = v.itemAtIndex(v.count - 1)
                harness.ok("CTCP request renders on the event path",
                           req !== null && req.isEvent === true
                           && String(req.bodyText).indexOf("* CTCP VERSION request from alice") === 0,
                           req === null ? "null" : ("isEvent=" + req.isEvent + " body=[" + req.bodyText + "]"))
                harness.ok("CTCP request is dim, not chat-coloured",
                           req !== null && req.bodyColor === req.fgDimColor && req.bodyColor !== req.fgPrimaryColor,
                           req === null ? "null" : ("body=" + req.bodyColor + " dim=" + req.fgDimColor))
                harness.ok("CTCP request has no hover state (nothing can reflow on hover)",
                           req !== null && req.hovered === undefined,
                           req === null ? "null" : ("hovered=" + req.hovered))
                harness.ok("CTCP VERSION reply shows the remote client string",
                           rep !== null && rep.isEvent === true
                           && String(rep.bodyMarkup).indexOf("irssi 1.4.5") !== -1,
                           rep === null ? "null" : ("markup=[" + rep.bodyMarkup + "]"))
                harness.ok("CTCP reply is dim, not chat-coloured",
                           rep !== null && rep.bodyColor === rep.fgDimColor && rep.bodyColor !== rep.fgPrimaryColor,
                           rep === null ? "null" : ("body=" + rep.bodyColor + " dim=" + rep.fgDimColor))
                harness.ok("both CTCP rows keep the same row height",
                           req !== null && rep !== null && req.implicitHeight === rep.implicitHeight,
                           (req !== null && rep !== null)
                               ? (req.implicitHeight + " vs " + rep.implicitHeight) : "null")
                var ordinary = v.itemAtIndex(0)
                harness.ok("ordinary chat still renders as chat (contrast case)",
                           ordinary !== null && ordinary.isEvent === false
                           && String(ordinary.bodyText).indexOf("* ") !== 0,
                           ordinary === null ? "null" : ("isEvent=" + ordinary.isEvent + " body=[" + ordinary.bodyText + "]"))
                break
            }
            case 7: {
                // the terminal palettes are all live-switchable
                var outDense = ThemeEngine.applyBuiltinTheme("amber")
                harness.ok("switch to amber", outDense === "" && ThemeEngine.mode === "dense"
                           && ThemeEngine.themeId === "amber")
                break
            }
            case 8: {
                if (!harness.win) { break }
                var viewDense = harness.findMessageView(harness.win.pageStack.get(1), 0)
                if (viewDense) {
                    var itD = viewDense.itemAtIndex(0)
                    harness.ok("delegate still renders the dense layout",
                               itD !== null && (itD.styleMode === undefined || itD.styleMode === 0),
                               itD ? ("styleMode=" + itD.styleMode) : "null")
                }
                break
            }
            case 9: {
                // and back to the default terminal palette
                var outBubble = ThemeEngine.applyBuiltinTheme("tui")
                harness.ok("switch back to tui", outBubble === "" && ThemeEngine.mode === "dense"
                           && ThemeEngine.themeId === "tui")
                if (harness.win) {
                    var viewB = harness.findMessageView(harness.win.pageStack.get(1), 0)
                    if (viewB) {
                        var itB = viewB.itemAtIndex(0)
                        harness.ok("delegate is dense after the theme switch",
                                   itB !== null && (itB.styleMode === undefined || itB.styleMode === 0),
                                   itB ? ("styleMode=" + itB.styleMode) : "null")
                    }
                }
                break
            }
            case 10: {
                // Settings pane: the CTCP VERSION toggle lives in the
                // Connection section, mirrors the persisted value (seeded OFF
                // here) and persists a change back through its config.
                var sp = harness.settingsPage()
                harness.ok("SettingsPage instantiated standalone", sp !== null)
                if (sp === null) { break }
                var aboutVersion = harness.findByPredicate(sp, function (o) {
                    return o.objectName === "aboutVersionText"
                }, 0)
                harness.ok("About uses the application version instead of a stale literal",
                           aboutVersion !== null
                           && aboutVersion.text.indexOf("# kIRC " + Qt.application.version + " —") === 0
                           && aboutVersion.text.indexOf("kIRC 0.1.0") < 0,
                           aboutVersion === null ? "missing" : aboutVersion.text)
                var toggle = harness.findByText(sp, "Reply to CTCP VERSION requests", 0)
                harness.ok("the CTCP VERSION toggle exists", toggle !== null)
                harness.ok("the toggle shows the persisted value (off)",
                           toggle !== null && toggle.checked === false,
                           toggle === null ? "null" : ("checked=" + toggle.checked))
                harness.ok("the CTCP hint says what the reply reveals",
                           harness.findTextContaining(sp, "client name and version", 0) !== null, "")
                // It belongs to the Connection section (index 1): selecting
                // another section hides the row entirely.
                sp.sectionIndex = 0
                var hiddenElsewhere = toggle !== null && !harness.completelyVisible(toggle)
                sp.sectionIndex = 1
                harness.ok("the toggle is in the Connection section",
                           hiddenElsewhere && toggle !== null && harness.completelyVisible(toggle),
                           hiddenElsewhere ? "hidden in Identity, visible in Connection" : "visible outside Connection")
                if (toggle !== null) {
                    toggle.checked = true
                    sp.persist()
                    harness.ok("toggling persists respondToCtcpVersion",
                               settingsCfg.respondToCtcpVersion === true && settingsCfg.saved === true,
                               "value=" + settingsCfg.respondToCtcpVersion + " saved=" + settingsCfg.saved)
                }

                // ---- the theme list + its search keywords (schema 4) -----
                var themeIds = ThemeEngine.availableThemeIds
                sp.setFilter("c64")
                harness.ok("settings search 'c64' finds the theme list",
                           sp.filter === "c64" && sp.themeListVisible() === true
                           && sp.sectionMatches(2) === true,
                           "visible=" + sp.themeListVisible())
                harness.ok("settings search keeps only the matching theme row",
                           sp.themeRowVisible("c64") === true
                           && sp.themeRowVisible("tui") === false,
                           "c64=" + sp.themeRowVisible("c64") + " tui=" + sp.themeRowVisible("tui"))
                sp.setFilter("commodore")
                harness.ok("settings search 'commodore' (keyword)", sp.themeListVisible() === true)
                sp.setFilter("bbs")
                harness.ok("settings search 'bbs' (keyword)", sp.themeListVisible() === true)
                sp.setFilter("dial-up")
                harness.ok("settings search 'dial-up' (keyword)", sp.themeListVisible() === true)
                sp.setFilter("dos")
                harness.ok("settings search 'dos' (keyword)", sp.themeListVisible() === true)
                sp.setFilter("outrun")
                harness.ok("settings search 'outrun' (keyword)", sp.themeListVisible() === true)
                var keywordsOk = true
                for (var ti = 0; ti < themeIds.length; ++ti) {
                    var kw = sp.themeSearchKeywords[themeIds[ti]]
                    if (kw === undefined || String(kw).length === 0) { keywordsOk = false }
                }
                harness.ok("every built-in theme carries search keywords", keywordsOk)
                sp.setFilter("")
                harness.ok("clearing the search shows the whole theme list again",
                           sp.themeListVisible() === true && sp.themeRowVisible("bbs") === true
                           && sp.themeRowVisible("tui") === true)

                // ---- p10: the Effects section ---------------------------
                // Five opt-in CRT effects, each a toggle + an intensity, all
                // OFF by default (they sit over the message text).  The pane
                // follows the config object, which is the source of truth.
                var fx = sp.sectionIds.indexOf("effects")
                harness.ok("the settings pane has an Effects section",
                           fx === 3 && sp.sectionName(fx) === "Effects",
                           "index=" + fx + " name=" + sp.sectionName(fx))
                var fxSearches = ["scanlines", "vignette", "grain", "flicker", "hum bar", "crt"]
                var fxFound = []
                for (var fxi = 0; fxi < fxSearches.length; ++fxi) {
                    sp.setFilter(fxSearches[fxi])
                    if (sp.sectionMatches(fx) !== true) { fxFound.push(fxSearches[fxi]) }
                }
                harness.ok("every effect name finds the Effects section",
                           fxFound.length === 0, "missing=" + fxFound.join(","))
                sp.setFilter("")
                sp.selectSection(fx)

                var sToggle = harness.findByText(sp, "Horizontal scanlines", 0)
                var vToggle = harness.findByText(sp, "Corner falloff", 0)
                var gToggle = harness.findByText(sp, "Static grain", 0)
                var fToggle = harness.findByText(sp, "Slow brightness flicker", 0)
                var hToggle = harness.findByText(sp, "Rolling hum bar", 0)
                harness.ok("every effect has a toggle",
                           sToggle !== null && vToggle !== null && gToggle !== null
                           && fToggle !== null && hToggle !== null)
                harness.ok("the toggles show the persisted defaults (all off)",
                           sToggle !== null && sToggle.checked === false
                           && vToggle !== null && vToggle.checked === false
                           && gToggle !== null && gToggle.checked === false
                           && fToggle !== null && fToggle.checked === false
                           && hToggle !== null && hToggle.checked === false,
                           sToggle === null ? "null" : ("scanlines=" + sToggle.checked))
                harness.ok("each effect row carries a hint",
                           harness.findTextContaining(sp, "before it existed", 0) !== null
                           || harness.findTextContaining(sp, "drawn above every layer", 0) !== null,
                           "")

                var sSlider = harness.findByPredicate(sp, function (o) { return o.objectName === "scanlineSlider" }, 0)
                var vSlider = harness.findByPredicate(sp, function (o) { return o.objectName === "vignetteSlider" }, 0)
                var gSlider = harness.findByPredicate(sp, function (o) { return o.objectName === "grainSlider" }, 0)
                var fSlider = harness.findByPredicate(sp, function (o) { return o.objectName === "flickerSlider" }, 0)
                var hSlider = harness.findByPredicate(sp, function (o) { return o.objectName === "humSlider" }, 0)
                harness.ok("every effect has an intensity slider",
                           sSlider !== null && vSlider !== null && gSlider !== null
                           && fSlider !== null && hSlider !== null)
                harness.ok("the sliders read the persisted amounts (35/30/10/4/8)",
                           sSlider !== null && sSlider.value === 35
                           && vSlider !== null && vSlider.value === 30
                           && gSlider !== null && gSlider.value === 10
                           && fSlider !== null && fSlider.value === 4
                           && hSlider !== null && hSlider.value === 8,
                           sSlider === null ? "null" : ("scanlines=" + sSlider.value
                                                        + " hum=" + (hSlider === null ? "null" : hSlider.value)))
                harness.ok("a slider is disabled while its effect is off",
                           sSlider !== null && sSlider.enabled === false)

                if (sToggle !== null && sSlider !== null) {
                    sToggle.checked = true
                    sToggle.toggled(true)
                    harness.ok("toggling Scanlines persists the switch",
                               settingsCfg.scanlines === true && settingsCfg.saved === true,
                               "scanlines=" + settingsCfg.scanlines + " saved=" + settingsCfg.saved)
                    harness.ok("the intensity slider enables with its effect",
                               sSlider.enabled === true)
                    sSlider.value = 60
                    harness.ok("moving the slider persists the amount",
                               settingsCfg.scanlineAmount === 60,
                               "amount=" + settingsCfg.scanlineAmount)
                    sSlider.value = 9000
                    harness.ok("the slider cannot leave 1..100",
                               settingsCfg.scanlineAmount === 100,
                               "amount=" + settingsCfg.scanlineAmount)
                    sSlider.value = 35
                    sToggle.checked = false
                    sToggle.toggled(false)
                    harness.ok("turning the switch back off persists too",
                               settingsCfg.scanlines === false && settingsCfg.scanlineAmount === 35,
                               "scanlines=" + settingsCfg.scanlines + " amount=" + settingsCfg.scanlineAmount)
                }
                harness.ok("the Effects section is only shown when selected",
                           harness.countTextContaining(sp, "Rolling hum bar") > 0)

                // ---- p10: the glass family lives here too ----------------
                // The standalone Glass pane was folded into this section, so a
                // search for "glass" must now land here (and no longer on
                // Appearance, which kept only the theme/font rows).
                harness.ok("the glass master is in the Effects section",
                           harness.findByText(sp, "Frosted glass effects", 0) !== null
                           && harness.findByText(sp, "Frost (blurred underlay)", 0) !== null
                           && harness.findByText(sp, "Reflection sheen", 0) !== null
                           && harness.findByText(sp, "Lit edges and depth", 0) !== null)
                sp.setFilter("glass")
                harness.ok("search 'glass' lands on Effects, not Appearance",
                           sp.sectionMatches(fx) === true && sp.sectionMatches(2) === false,
                           "appearance=" + sp.sectionMatches(2) + " effects=" + sp.sectionMatches(fx))
                sp.setFilter("")
                var reflToggle = harness.findByText(sp, "Specular chrome gloss", 0)
                var reflSlider = harness.findByPredicate(sp, function (o) {
                    return o.objectName === "reflectionSlider"
                }, 0)
                harness.ok("Reflection has a toggle and an intensity",
                           reflToggle !== null && reflSlider !== null
                           && reflToggle.checked === false && reflSlider.value === 25,
                           reflToggle === null ? "null" : ("checked=" + reflToggle.checked
                                                           + " amount=" + (reflSlider === null ? "null"
                                                                                               : reflSlider.value)))
                harness.ok("the Reflection hint says it is chrome-only",
                           harness.findTextContaining(sp, "never a mirror of the message log", 0) !== null)
                harness.ok("the reflection slider is disabled while its effect is off",
                           reflSlider !== null && reflSlider.enabled === false)
                if (reflToggle !== null && reflSlider !== null) {
                    reflToggle.checked = true
                    reflToggle.toggled(true)
                    harness.ok("toggling Reflection persists the pref",
                               settingsCfg.reflection === true && settingsCfg.saved === true,
                               "reflection=" + settingsCfg.reflection)
                    reflSlider.value = 45
                    harness.ok("the reflection intensity persists",
                               settingsCfg.reflectionAmount === 45,
                               "amount=" + settingsCfg.reflectionAmount)
                    reflSlider.value = 25
                    reflToggle.checked = false
                    reflToggle.toggled(false)
                    harness.ok("Reflection off again",
                               settingsCfg.reflection === false && settingsCfg.reflectionAmount === 25)
                }
                break
            }
            case 11: {
                // ---- navigation (p8 follow-up) --------------------------
                // While a session is live, [back] must not offer a route out
                // of it: it is redundant with Disconnect, which disconnects.
                var backBtn = harness.findBackButton()
                harness.ok("the header carries the [back] control", backBtn !== null,
                           backBtn === null ? "null" : ("visible=" + backBtn.visible))
                harness.ok("[back] is hidden while the session is live",
                           backBtn !== null && backBtn.visible === false,
                           backBtn === null ? "null" : ("visible=" + backBtn.visible))
                // On the settings pane it is genuinely useful ("back to
                // chat"), so it stays there.
                if (harness.win) { harness.win.openSettings() }
                break
            }
            case 12: {
                if (!harness.win) { break }
                harness.ok("settings pushed on top of a live session",
                           harness.win.pageStack.depth === 3
                           && harness.win.currentPageIsSettings() === true,
                           "depth=" + harness.win.pageStack.depth)
                var backSettings = harness.findBackButton()
                harness.ok("[back] is offered on the settings pane", backSettings !== null
                           && backSettings.visible === true,
                           backSettings === null ? "null" : ("visible=" + backSettings.visible))
                // It pops back to the live chat.
                harness.win.pageStack.pop()
                harness.ok("[back] from settings returns to the live session",
                           harness.win.pageStack.depth === 2
                           && harness.win.currentPageIsSettings() === false,
                           "depth=" + harness.win.pageStack.depth)
                // The guard: even a pop to the connection form while the
                // session is live cannot strand it — the next connect-state
                // signal lands back on the chat page.  (This is also the tray
                // path's protection: it can connect without the UI pushing.)
                harness.win.pageStack.pop()
                harness.ok("a pop lands on the connection form", harness.win.pageStack.depth === 1,
                           "depth=" + harness.win.pageStack.depth)
                harness.win.bridge.connection_state = 2
                harness.win.bridge.state_changed(2)
                harness.ok("a live session is never stranded on the connection form",
                           harness.win.pageStack.depth === 2
                           && harness.win.currentPageIsSettings() === false,
                           "depth=" + harness.win.pageStack.depth)
                break
            }
            case 13: {
                // ---- p9: one identity line, one [menu], buffer-aware title --
                if (harness.win) {
                    var header = harness.win.header
                    harness.ok("no [join] control in the header",
                               harness.countControls(header, "[join]") === 0,
                               "found=" + harness.countControls(header, "[join]"))
                    harness.ok("exactly one [menu] control in the header",
                               harness.countControls(header, "[menu]") === 1,
                               "found=" + harness.countControls(header, "[menu]"))
                    var folded = []
                    var foldedTexts = ["[settings]", "[disconnect]"]
                    for (var fi = 0; fi < foldedTexts.length; ++fi) {
                        if (harness.countControls(header, foldedTexts[fi]) > 0) {
                            folded.push(foldedTexts[fi])
                        }
                    }
                    harness.ok("[settings]/[disconnect] folded into [menu]",
                               folded.length === 0, folded.join(","))

                    // ---- p10: [search] [theme] [effects] [menu] ------------
                    // Both new controls are real header buttons in this order,
                    // to the right of everything else ([back] leftmost).
                    var btns = harness.headerButtonTexts()
                    harness.ok("the toolbar's right side is exactly [search] [theme] [effects] [menu]",
                               btns.length >= 4
                               && btns.slice(btns.length - 4).join("|")
                                  === "[search]|[theme]|[effects]|[menu]",
                               btns.join("|"))
                    harness.ok("[back] stays to the left of them",
                               btns.indexOf("[back]") >= 0
                               && btns.indexOf("[back]") < btns.indexOf("[search]"),
                               btns.join("|"))
                    harness.ok("each new control appears exactly once",
                               harness.countControls(header, "[theme]") === 1
                               && harness.countControls(header, "[effects]") === 1)

                    // The [theme] control owns the same list the [menu] Theme
                    // row opens (one popup, two entry points).
                    var themeBtn = harness.headerButton("[theme]")
                    var themePopup = harness.buttonMenu("[theme]", "Theme")
                    harness.ok("the [theme] control owns the theme list",
                               themeBtn !== null && themePopup !== null
                               && themePopup.count === ThemeEngine.availableThemeIds.length,
                               themePopup === null ? "null" : ("rows=" + themePopup.count))

                    // The [effects] control owns the one effects popup: the
                    // glass family first, then the CRT family, then the jump to
                    // the settings section.  Glass is on by default (p8), the
                    // CRT set is off — that is what the marks show.
                    var fxBtn = harness.headerButton("[effects]")
                    var effectsPopup = harness.buttonMenu("[effects]", "Effects")
                    harness.ok("the [effects] control owns the effects popup",
                               fxBtn !== null && effectsPopup !== null)
                    var fxRows = harness.menuRowTexts(effectsPopup)
                    harness.ok("the popup groups glass, then crt, then the settings row",
                               fxRows.join("|") === "[*] Frost|[*] Sheen|[*] Edges|[ ] Reflection|[sep]|"
                                             + "[ ] Scanlines|[ ] Vignette|[ ] Grain|[ ] Flicker|[ ] Hum bar|"
                                             + "[sep]|Effects settings…",
                               fxRows.join("|"))

                    // A glass row turned ON while the master is off must switch
                    // the master on: no dead toggle.
                    if (effectsPopup !== null) {
                        ThemeEngine.glassEffects = false
                        ThemeEngine.glassSheen = false
                        effectsPopup.itemAt(1).triggered()          // Sheen
                        harness.ok("a glass row turned on with the master off switches the master on",
                                   ThemeEngine.glassSheen === true && ThemeEngine.glassEffects === true,
                                   "sheen=" + ThemeEngine.glassSheen + " master=" + ThemeEngine.glassEffects)

                        // ---- the overlay is inert with every effect off -----
                        var ovlLoader = harness.overlayLoader()
                        harness.ok("the effects overlay is stacked above the header",
                                   ovlLoader !== null
                                   && ovlLoader.parent === harness.win.contentItem.parent.parent
                                   && ovlLoader.z > harness.win.header.z,
                                   ovlLoader === null ? "null"
                                                      : ("parent==root? "
                                                         + (ovlLoader.parent === harness.win.contentItem.parent.parent)
                                                         + " z=" + ovlLoader.z
                                                         + " headerZ=" + harness.win.header.z))
                        harness.ok("with every effect off the overlay adds no nodes at all",
                                   harness.win.effectsActive === false
                                   && harness.overlayItem() === null,
                                   "active=" + harness.win.effectsActive)

                        // Flip one CRT row through the popup and inspect what
                        // the window instantiates.
                        effectsPopup.itemAt(5).triggered()          // Scanlines
                        harness.ok("the row toggles the effect and its mark follows",
                                   harness.win.scanlinesOn === true
                                   && String(effectsPopup.itemAt(5).text).indexOf("[*] Scanlines") === 0,
                                   String(effectsPopup.itemAt(5).text))
                        var ovl = harness.overlayItem()
                        harness.ok("switching an effect on instantiates the overlay", ovl !== null)
                        if (ovl !== null) {
                            var headerPt = harness.win.header.mapToItem(ovl, 0, 0)
                            harness.ok("the overlay covers the whole window, header included",
                                       ovl.width === harness.win.width
                                       && ovl.height === harness.win.height
                                       && headerPt.y >= 0
                                       && headerPt.y + harness.win.header.height <= ovl.height + 0.5,
                                       "overlay=" + ovl.width + "x" + ovl.height
                                       + " window=" + harness.win.width + "x" + harness.win.height
                                       + " headerAtY=" + headerPt.y + "+" + harness.win.header.height)
                            harness.ok("the overlay carries no ListView and never scans one",
                                       harness.findMessageView(ovl, 0) === null
                                       && harness.countNodes(ovl, function (o) {
                                              return typeof o.itemAtIndex === "function"
                                          }, 0) === 0)
                            harness.ok("the overlay captures nothing (no ShaderEffectSource/MultiEffect)",
                                       harness.countNodes(ovl, function (o) {
                                              return o.shaderSource !== undefined || o.blurSource !== undefined
                                          }, 0) === 0)
                            harness.ok("the overlay is not a per-row Repeater",
                                       harness.countNodes(ovl, function (o) {
                                              return typeof o.model !== "undefined" && typeof o.count === "number"
                                          }, 0) === 0)
                            harness.ok("the overlay takes no input", ovl.enabled === false)
                            harness.ok("only the scanline layer is instantiated",
                                       harness.countNodes(ovl, function (o) {
                                              return typeof o.active !== "undefined" && o.active === true
                                          }, 0) === 1)
                        }
                        effectsPopup.itemAt(5).triggered()          // Scanlines off
                        harness.ok("switching it off removes the nodes again",
                                   harness.win.scanlinesOn === false && harness.overlayItem() === null)

                        // ---- reflection: static chrome, never the log -------
                        effectsPopup.itemAt(3).triggered()          // Reflection
                        harness.ok("the Reflection row turns the gloss on",
                                   harness.win.reflectionOn === true
                                   && String(effectsPopup.itemAt(3).text).indexOf("[*] Reflection") === 0)
                        var reflItem = harness.overlayItem()
                        harness.ok("the gloss instantiates its own layer", reflItem !== null)
                        if (reflItem !== null) {
                            harness.ok("the gloss is clipped to the chrome band, not the log",
                                       harness.countNodes(reflItem, function (o) {
                                              return o.objectName === "reflectionChromeBand"
                                          }, 0) === 1
                                       && harness.countNodes(reflItem, function (o) {
                                              return typeof o.itemAtIndex === "function"
                                          }, 0) === 0)
                        }
                        effectsPopup.itemAt(3).triggered()          // Reflection off
                        harness.ok("turning the gloss off restores the no-node state",
                                   harness.win.reflectionOn === false
                                   && harness.overlayItem() === null)
                        // Leave the glass family as it was found: on.
                        ThemeEngine.glassEffects = true
                        ThemeEngine.glassSheen = true

                        // ---- software-scene-graph degradation -----------------
                        // Windows ships the Qt Quick SOFTWARE renderer as its
                        // default backend, and this offscreen run renders on
                        // exactly that renderer — the pin above was what kept
                        // the capability ON here.  Released, the system must
                        // degrade honestly: capability reads false with a
                        // reason, the glass sheet renders nothing (no
                        // MultiEffect node at all), the overlay does not
                        // instantiate even with an effect switched on, and
                        // the popup leads with its caption while the toggles
                        // are inert and write no preference.  The stored
                        // prefs themselves are never touched by any of it.
                        ThemeEngine._effectsForceSupported = false
                        if (ThemeEngine.effectsSupported === false) {
                            harness.ok("releasing the pin exposes the unsupported renderer",
                                       ThemeEngine.effectsUnsupportedReason.length > 0)

                            var dSheet = harness.findByPredicate(harness.win.header, function (o) {
                                return o.objectName === "glassSurface"
                            }, 0)
                            harness.ok("unsupported: the glass sheet renders nothing",
                                       dSheet !== null && dSheet.visible === false)
                            harness.ok("unsupported: the sheet holds no MultiEffect node",
                                       dSheet !== null
                                       && harness.countNodes(dSheet, function (o) {
                                              return o.blurEnabled !== undefined
                                          }, 0) === 0)

                            harness.win.scanlinesOn = true
                            harness.ok("unsupported: the overlay never instantiates",
                                       harness.win.effectsActive === true
                                       && harness.overlayItem() === null,
                                       "active=" + harness.win.effectsActive
                                       + " overlay=" + (harness.overlayItem() === null))
                            harness.win.scanlinesOn = false

                            var dFxRows = harness.menuRowTexts(effectsPopup)
                            harness.ok("unsupported: the popup leads with the capability caption",
                                       dFxRows.length === 13
                                       && dFxRows[0] === ThemeEngine.effectsUnsupportedReason,
                                       dFxRows.join("|"))
                            // With the caption at index 0 every row shifts by
                            // one: Frost is at 1, the separator at 5, the CRT
                            // toggles from 6 on.
                            harness.ok("unsupported: the effect toggles are inert",
                                       effectsPopup.itemAt(1).enabled === false
                                       && effectsPopup.itemAt(6).enabled === false)
                            effectsPopup.itemAt(6).triggered()      // direct signal: must be refused
                            harness.ok("unsupported: triggering a row writes no preference",
                                       harness.win.scanlinesOn === false)
                        } else {
                            // A hardware scene graph (a watched run, QPA=xcb
                            // with GL): nothing to degrade, and the probe
                            // following the renderer is the contract.
                            harness.ok("the capability probe reads a hardware scene graph as supported",
                                       ThemeEngine.effectsSupported === true)
                        }
                        // The pin comes back: everything below this point
                        // asserts the supported UI again.
                        ThemeEngine._effectsForceSupported = true
                        harness.ok("restoring the pin restores the effects",
                                   ThemeEngine.effectsSupported === true)
                    }
                    // One nick, once: the identity line.  (The old header showed
                    // it in the subtitle AND again after the status tag.)
                    var nick = harness.win.bridge.nickname
                    harness.ok("the header shows the nick exactly once",
                               nick.length > 0 && harness.countTextContaining(header, nick) === 1,
                               "found=" + harness.countTextContaining(header, nick) + " nick=" + nick)
                    harness.ok("the identity line reads 'nick @ server'",
                               harness.countTextContaining(header, "@ irc.test.example") === 1,
                               "server items=" + harness.countTextContaining(header, "@ irc.test.example"))
                    harness.ok("the status tag does not repeat the nick",
                               String(harness.win.statusTag).indexOf(nick) === -1,
                               harness.win.statusTag)
                    // The menu: exact order, separator before the destructive
                    // pair, Exit last.
                    var menu = harness.findAppMenu()
                    harness.ok("the [menu] button owns the application menu", menu !== null)
                    if (menu !== null) {
                        var order = []
                        for (var mi = 0; mi < menu.count; ++mi) {
                            var rowText = menu.itemAt(mi).text
                            order.push(rowText === undefined ? "[sep]" : String(rowText))
                        }
                        harness.ok("menu order: Search, Settings, Theme, Help, —, Disconnect, Exit",
                                   order.join("|") === "Search|Settings|Theme|Help|[sep]|Disconnect|Exit",
                                   order.join("|"))
                    }
                    // ---- the window title follows the buffer type ----------
                    var titlePage = harness.win.pageStack.depth > 1
                            ? harness.win.pageStack.get(1) : null
                    if (titlePage === null) {
                        harness.failures++
                        console.error("FAIL title check: no chat page")
                    } else {
                        titlePage.openChannel("#kirc")
                        harness.ok("window title keeps the channel '#'",
                                   harness.win.title.indexOf("#") >= 0
                                   && harness.win.title.indexOf("kirc") >= 0,
                                   harness.win.title)
                        titlePage.openChannel("querynick")
                        harness.ok("window title has no '#' for a query",
                                   harness.win.title.indexOf("#") < 0
                                   && harness.win.title.indexOf("querynick") >= 0,
                                   harness.win.title)
                        titlePage.openChannel("*server*")
                        harness.ok("window title reads 'Server' for the console",
                                   harness.win.title.indexOf("Server") >= 0
                                   && harness.win.title.indexOf("#") < 0,
                                   harness.win.title)
                        titlePage.openChannel("#kirc")
                    }
                }
                // disconnect must fall back to the connection form
                if (harness.win) { harness.win.bridge.disconnect_server() }
                break
            }
            case 14: {
                harness.ok("disconnect returned to the connection form", harness.win !== null && harness.win.pageStack.depth === 1,
                           "depth=" + (harness.win ? harness.win.pageStack.depth : -1))
                console.error(harness.failures === 0 ? "SMOKE-RESULT: ALL PASS" : ("SMOKE-RESULT: " + harness.failures + " FAILURES"))
                Qt.exit(harness.failures === 0 ? 0 : 1)
                break
            }
            }
        }
    }

    /// The settings pane instance (null until created / on failure).
    function settingsPage() {
        return harness.settingsPageItem
    }

    /// Count of objects under `root` matching `pred` (children only — popups
    /// live in `resources` and are deliberately out of scope here).
    function countNodes(root, pred, depth) {
        if (root === null || root === undefined || depth > 18) { return 0 }
        var n = 0
        var hit = false
        try {
            hit = pred(root) === true
        } catch (e) {
            hit = false
        }
        if (hit) { ++n }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            n += harness.countNodes(kids[i], pred, depth + 1)
        }
        return n
    }

    /// The header's bracketed text controls in tree (== declaration) order:
    /// `[back] [search] [theme] [effects] [menu]`.
    ///
    /// The walk never descends into `resources` (where a control's popups
    /// live), so the `[*]`/`[ ]` menu rows are not collected as if they were
    /// header controls.
    function headerButtonTexts() {
        var out = []
        if (harness.win === null || harness.win.header === undefined) { return out }
        var items = harness.collectChildTextItems(harness.win.header, 0, [])
        for (var i = 0; i < items.length; ++i) {
            var t = items[i].text
            if (items[i].pressed !== undefined && t !== undefined
                    && String(t).charAt(0) === "[") {
                out.push(String(t))
            }
        }
        return out
    }

    /// Like collectTextItems, but only through `children` and `contentItem` —
    /// never through `resources`, so a control's popup rows are not collected
    /// as if they were header controls.
    function collectChildTextItems(root, depth, out) {
        if (root === null || root === undefined || depth > 18) { return out }
        if (root.text !== undefined && out.indexOf(root) === -1) { out.push(root) }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            harness.collectChildTextItems(kids[i], depth + 1, out)
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            harness.collectChildTextItems(root.contentItem, depth + 1, out)
        }
        return out
    }

    /// The header button whose text is exactly `text` (a Control, not the
    /// label that mirrors it).
    function headerButton(text) {
        if (harness.win === null || harness.win.header === undefined) { return null }
        var pred = function (o) { return String(o.text) === text && o.pressed !== undefined }
        return harness.findByPredicate(harness.win.header, pred, 0)
    }

    /// A popup a header button owns, by its title.  A Menu declared inside a
    /// control is a Popup and therefore lives in the control's `resources`
    /// (not `children`), which is why both pools are scanned.
    function buttonMenu(text, title) {
        var btn = harness.headerButton(text)
        if (btn === null) { return null }
        var pools = []
        if (btn.resources !== undefined && btn.resources !== null) { pools.push(btn.resources) }
        if (btn.children !== undefined && btn.children !== null) { pools.push(btn.children) }
        for (var p = 0; p < pools.length; ++p) {
            for (var i = 0; i < pools[p].length; ++i) {
                var k = pools[p][i]
                if (typeof k.popup === "function" && typeof k.itemAt === "function"
                        && String(k.title) === title) {
                    return k
                }
            }
        }
        return null
    }

    /// The effects overlay Loader main.qml stacks above the page stack.  It is
    /// parented to the window's root item (see main.qml), so the search starts
    /// there and falls back to contentItem.
    function overlayLoader() {
        if (harness.win === null || harness.win.contentItem === undefined) { return null }
        var pred = function (o) { return o.objectName === "effectsOverlayLoader" }
        var ci = harness.win.contentItem
        var host = (ci !== null && ci !== undefined && ci.parent !== null
                    && ci.parent !== undefined && ci.parent.parent !== null
                    && ci.parent.parent !== undefined) ? ci.parent.parent : ci
        var found = harness.findByPredicate(host, pred, 0)
        if (found !== null) { return found }
        return harness.findByPredicate(ci, pred, 0)
    }

    /// The instantiated overlay, or null while every effect is off.
    function overlayItem() {
        var l = harness.overlayLoader()
        return (l === null || l === undefined) ? null : l.item
    }

    /// Every `text` of the rows of a menu, "[sep]" for a separator.
    function menuRowTexts(menu) {
        var out = []
        if (menu === null) { return out }
        for (var i = 0; i < menu.count; ++i) {
            var row = menu.itemAt(i)
            out.push(row.text === undefined ? "[sep]" : String(row.text))
        }
        return out
    }

    /// Depth-first search for a control whose `text` matches exactly and that
    /// has a `checked` property (the settings toggle under test).
    function findByText(root, text, depth) {
        if (root === null || root === undefined || depth > 18) { return null }
        if (root.text === text && root.checked !== undefined) { return root }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findByText(kids[i], text, depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findByText(root.contentItem, text, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }

    /// Depth-first search for any item whose `text` contains `fragment`.
    function findTextContaining(root, fragment, depth) {
        if (root === null || root === undefined || depth > 18) { return null }
        if (root.text !== undefined && root.text !== null
                && String(root.text).indexOf(fragment) !== -1) {
            return root
        }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findTextContaining(kids[i], fragment, depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findTextContaining(root.contentItem, fragment, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }

    /// The header's [back] ToolButton: an inline component whose text is the
    /// bracketed translation, reachable through the window's header item (and,
    /// as a fallback, its contentItem).
    function findBackButton() {
        var pred = function (o) { return o.text === "[back]" && o.pressed !== undefined }
        var roots = []
        if (harness.win.header !== undefined && harness.win.header !== null) {
            roots.push(harness.win.header)
        }
        if (harness.win.contentItem !== undefined && harness.win.contentItem !== null) {
            roots.push(harness.win.contentItem)
        }
        for (var i = 0; i < roots.length; ++i) {
            var f = harness.findByPredicate(roots[i], pred, 0)
            if (f !== null) { return f }
        }
        return null
    }

    /// Every object under `root` that carries a `text` property, deduped
    /// (a Control's contentItem is also reachable through `children`, and
    /// popups declared inside a control land in its `resources`).
    /// The header's own bookkeeping — used to count controls and to prove a
    /// string appears exactly once (p9: the identity line's nick).
    function collectTextItems(root, depth, out) {
        if (root === null || root === undefined || depth > 18) { return out }
        if (root.text !== undefined && out.indexOf(root) === -1) { out.push(root) }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            harness.collectTextItems(kids[i], depth + 1, out)
        }
        var res = root.resources || []
        for (var r = 0; r < res.length; ++r) {
            harness.collectTextItems(res[r], depth + 1, out)
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            harness.collectTextItems(root.contentItem, depth + 1, out)
        }
        return out
    }

    /// Count of Controls (objects with a `pressed` property) under `root`
    /// whose `text` matches exactly.  The `pressed` guard skips the
    /// contentItem Label that mirrors a button's text.
    function countControls(root, text) {
        if (root === undefined || root === null) { return 0 }
        var items = harness.collectTextItems(root, 0, [])
        var n = 0
        for (var i = 0; i < items.length; ++i) {
            if (String(items[i].text) === text && items[i].pressed !== undefined) { ++n }
        }
        return n
    }

    /// Count of items under `root` whose `text` contains `fragment`.
    function countTextContaining(root, fragment) {
        if (root === undefined || root === null) { return 0 }
        var items = harness.collectTextItems(root, 0, [])
        var n = 0
        for (var i = 0; i < items.length; ++i) {
            if (items[i].text !== undefined
                    && String(items[i].text).indexOf(fragment) !== -1) { ++n }
        }
        return n
    }

    /// The header's [menu] button (its text is the bracketed translation and
    /// it is the control the popup is anchored to).
    function findMenuButton() {
        if (harness.win.header === undefined || harness.win.header === null) { return null }
        var pred = function (o) { return o.text === "[menu]" && o.pressed !== undefined }
        return harness.findByPredicate(harness.win.header, pred, 0)
    }

    /// The application Menu the [menu] control owns: the one whose first row
    /// is Search.  Menus declared inside a control are Popups, so they live
    /// in its `resources` list (not `children`); both are scanned.  The theme
    /// picker is the sibling Menu of the same button.
    function findAppMenu() {
        var btn = harness.findMenuButton()
        if (btn === null) { return null }
        var pools = []
        if (btn.resources !== undefined && btn.resources !== null) { pools.push(btn.resources) }
        if (btn.children !== undefined && btn.children !== null) { pools.push(btn.children) }
        for (var p = 0; p < pools.length; ++p) {
            var pool = pools[p]
            for (var i = 0; i < pool.length; ++i) {
                var k = pool[i]
                if (typeof k.itemAt === "function" && typeof k.popup === "function"
                        && k.count > 0 && k.itemAt(0) !== null
                        && String(k.itemAt(0).text) === "Search") {
                    return k
                }
            }
        }
        return null
    }

    /// Depth-first search for an item matching `pred` (used for controls whose
    /// identity is not a single text, e.g. the header's [back] ToolButton).
    function findByPredicate(root, pred, depth) {
        if (root === null || root === undefined || depth > 18) { return null }
        var hit = false
        try {
            hit = pred(root) === true
        } catch (e) {
            hit = false
        }
        if (hit) { return root }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findByPredicate(kids[i], pred, depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findByPredicate(root.contentItem, pred, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }

    /// True when the item and every ancestor is visible (proves a row belongs
    /// to the section that is actually selected).
    function completelyVisible(item) {
        var it = item
        while (it !== null && it !== undefined) {
            if (it.visible === false) { return false }
            it = it.parent
        }
        return true
    }

    /// Index of the first recorded call of `fn` in the bridge double's call
    /// list (-1 when it was never called).  Used to assert call ORDER — the
    /// CTCP VERSION reply preference must reach the bridge before
    /// connect_server.
    function callIndex(fn) {
        var list = harness.win.bridge.calls
        for (var i = 0; i < list.length; ++i) {
            if (list[i].fn === fn) {
                return i
            }
        }
        return -1
    }

    // Depth-first search for the message ListView: the only ListView whose
    // model is the MessageListModel (the channel sidebar's model is a plain JS
    // array and has no append()).
    function findMessageView(root, depth) {
        if (root === null || root === undefined || depth > 14) { return null }
        if (typeof root.positionViewAtEnd === "function" && root.model !== undefined
                && root.model !== null && typeof root.model.append === "function") {
            return root
        }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findMessageView(kids[i], depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findMessageView(root.contentItem, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }
}
