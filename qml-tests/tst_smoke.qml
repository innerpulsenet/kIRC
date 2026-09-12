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
            harness.ok("the theme list offers all ten built-ins",
                       ThemeEngine.availableThemeIds.length === 10
                       && ["tui", "phosphor", "amber", "ice", "breeze", "bbs", "c64", "vt",
                           "ega", "synthwave"].every(function (id) {
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
                if (harness.win) {
                    harness.ok("initialPage is the connection form", harness.win.pageStack.depth === 1)
                    harness.ok("bridge exposed on window", harness.win.bridge !== null && harness.win.bridge.connection_state === 0)
                    harness.ok("header shows Disconnected", harness.win.statusText === "Disconnected", harness.win.statusText)
                }
                break
            case 2:
                if (!harness.win) { break }
                var cp = harness.win.pageStack.initialPage
                cp.host = "irc.test.example"
                cp.nickname = "smoketester"
                cp.port = "6697"
                harness.ok("ConnectPage form valid after filling", cp.formValid === true)
                cp.tryConnect()
                break
            case 3: {
                if (!harness.win) { break }
                harness.ok("connect pushed the chat page", harness.win.pageStack.depth === 2, "depth=" + harness.win.pageStack.depth)
                harness.ok("state = connected", harness.win.bridge.connection_state === 2)
                harness.ok("header shows Connected", harness.win.statusText === "Connected", harness.win.statusText)
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
