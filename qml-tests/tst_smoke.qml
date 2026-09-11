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

            // built-ins
            out = ThemeEngine.applyBuiltinTheme("neon")
            harness.ok("applyBuiltinTheme(neon)", out === "" && ThemeEngine.mode === "bubble" && ThemeEngine.themeName === "Neon", "mode=" + ThemeEngine.mode)
            harness.ok("neon bubbleRadius", ThemeEngine.bubbleRadius === 12 && ThemeEngine.bubbleSpacing === 8)

            out = ThemeEngine.applyBuiltinTheme("breeze-dark-default")
            harness.ok("applyBuiltinTheme(breeze)", out === "" && ThemeEngine.mode === "dense")

            out = ThemeEngine.applyBuiltinTheme("nope")
            harness.ok("applyBuiltinTheme(unknown) reports error", out !== "" && ThemeEngine.configError !== "")

            // bad JSON must not clobber the active theme
            out = ThemeEngine.applyThemeJson("{ not json")
            harness.ok("applyThemeJson(bad) reports error", out !== "" && ThemeEngine.mode === "dense")

            // partial JSON is merged over defaults
            out = ThemeEngine.applyThemeJson(JSON.parse('{"id":"custom","name":"Custom","mode":"bubble","fonts":{"messageSize":11}}'))
            harness.ok("applyThemeJson(partial) merges defaults",
                       out === "" && ThemeEngine.mode === "bubble" && ThemeEngine.messageSize === 11
                       && ThemeEngine.nickLightnessDark === 0.62 && ThemeEngine.bubbleRadius === 8,
                       "r=" + ThemeEngine.bubbleRadius + " l=" + ThemeEngine.nickLightnessDark)

            out = ThemeEngine.applyThemeJson('{"name":"From String","mode":"dense"}')
            harness.ok("applyThemeJson(JSON string)", out === "" && ThemeEngine.themeName === "From String" && ThemeEngine.mode === "dense")

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

            // hashing
            harness.ok("hashNick stable", ThemeEngine.hashNick("Alice") === ThemeEngine.hashNick("alice"))

            // escaping / linkify (never renders injected markup)
            var f = ThemeEngine.formatMessage("<b>bold</b> see https://kde.org now")
            harness.ok("formatMessage escapes html", f.indexOf("&lt;b&gt;") === 0, f)
            harness.ok("formatMessage linkifies", f.indexOf("<a href=\"https://kde.org\">https://kde.org</a>") > 0, f)

            // luminance / dark detection
            harness.ok("luminance black", ThemeEngine.isDark("#000000"))
            harness.ok("luminance white", !ThemeEngine.isDark("#ffffff"))

            ThemeEngine.applyBuiltinTheme("breeze-dark-default")
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
                    harness.ok("3 messages rendered", view.count === 3, "count=" + view.count)
                    var item = view.itemAtIndex(0)
                    harness.ok("delegate created from roles", item !== null && item.nick === "alice" && item.text !== undefined,
                               item ? ("nick=" + item.nick + " ts=" + item.timestamp) : "null")
                    harness.ok("dense mode active", item !== null && item.styleMode === 0)
                    var hl = view.itemAtIndex(2)
                    harness.ok("highlight role mapped", hl !== null && hl.isHighlight === true)
                    var own = view.itemAtIndex(1)
                    harness.ok("isSelf role mapped", own !== null && own.isSelf === true)
                }
                break
            case 5:
                // theme switch flips the delegate style without recreating it
                var out = ThemeEngine.applyBuiltinTheme("neon")
                harness.ok("switch to neon", out === "" && ThemeEngine.mode === "bubble")
                break
            case 6:
                if (!harness.win) { break }
                var chat2 = harness.win.pageStack.get(1)
                var view2 = harness.findMessageView(chat2, 0)
                if (view2) {
                    var it = view2.itemAtIndex(0)
                    harness.ok("delegate switched to bubble mode", it !== null && it.styleMode === 1,
                               it ? ("styleMode=" + it.styleMode) : "null")
                    harness.ok("bubble colour applied", it !== null && it.bubbleColor !== undefined)
                }
                break
            case 7:
                // disconnect must fall back to the connection form
                if (harness.win) { harness.win.bridge.disconnect_server() }
                break
            case 8:
                harness.ok("disconnect returned to the connection form", harness.win !== null && harness.win.pageStack.depth === 1,
                           "depth=" + (harness.win ? harness.win.pageStack.depth : -1))
                console.error(harness.failures === 0 ? "SMOKE-RESULT: ALL PASS" : ("SMOKE-RESULT: " + harness.failures + " FAILURES"))
                Qt.exit(harness.failures === 0 ? 0 : 1)
                break
            }
        }
    }

    // Depth-first search for the message ListView: the only ListView whose
    // model is the MessageListModel (the channel sidebar's model is a JS array).
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
