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
            case 3:
                if (!harness.win) { break }
                harness.ok("connect pushed the chat page", harness.win.pageStack.depth === 2, "depth=" + harness.win.pageStack.depth)
                harness.ok("state = connected", harness.win.bridge.connection_state === 2)
                harness.ok("header shows Connected", harness.win.statusText === "Connected", harness.win.statusText)
                break
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
                }
                break
            case 5:
                // the terminal palettes are all live-switchable
                var outDense = ThemeEngine.applyBuiltinTheme("amber")
                harness.ok("switch to amber", outDense === "" && ThemeEngine.mode === "dense"
                           && ThemeEngine.themeId === "amber")
                break
            case 6:
                if (!harness.win) { break }
                var viewDense = harness.findMessageView(harness.win.pageStack.get(1), 0)
                if (viewDense) {
                    var itD = viewDense.itemAtIndex(0)
                    harness.ok("delegate still renders the dense layout",
                               itD !== null && (itD.styleMode === undefined || itD.styleMode === 0),
                               itD ? ("styleMode=" + itD.styleMode) : "null")
                }
                break
            case 7:
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
            case 8:
                // disconnect must fall back to the connection form
                if (harness.win) { harness.win.bridge.disconnect_server() }
                break
            case 9:
                harness.ok("disconnect returned to the connection form", harness.win !== null && harness.win.pageStack.depth === 1,
                           "depth=" + (harness.win ? harness.win.pageStack.depth : -1))
                console.error(harness.failures === 0 ? "SMOKE-RESULT: ALL PASS" : ("SMOKE-RESULT: " + harness.failures + " FAILURES"))
                Qt.exit(harness.failures === 0 ? 0 : 1)
                break
            }
        }
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
