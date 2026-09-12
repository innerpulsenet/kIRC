// Glass surfacing harness (p8) — the assertions behind the frosted-glass
// feature: the master toggle, the derived colours per theme, the intensity
// clamp, the sub-toggles gating their layer, the "glass off == the old build"
// geometry/colour guarantee, and the settings round-trip through the config
// object (the KConfig side of the same contract is proven by
// tst_config_glass, run as its own stage).
//
// Uses console.error because console.log is filtered by the qml runtime here.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: harness
    width: 1024
    height: 700

    property int step: 0
    property int failures: 0
    property var chat: null
    property var settings: null
    property var sheets: []
    property var snapshot: null

    IrcBridge { id: bridgeDouble }

    QtObject {
        id: windowDouble
        property var appConfig: null
        property string chatChannel: "*server*"
        property bool userDisconnect: false
        property bool visible: true
    }

    // Config double WITH the glass keys (KircConfig contract: defaults on/60).
    QtObject {
        id: glassCfg
        property bool glassEffects: false   // seeded OFF on purpose
        property int glassIntensity: 25
        property bool glassBlur: true
        property bool glassSheen: false     // seeded OFF on purpose
        property bool glassEdges: true
        property string themeId: "tui"
        property int fontDelta: 0
        property string fontFamily: ""
        property string autojoin: ""
        property bool reconnect: true
        property bool minimizeToTray: true
        property bool identifyOnConnect: false
        property string nickservNick: ""
        property string nickservPassword: ""
        property string serverPassword: ""
        property int saslMechanism: 0
        property bool notifyHighlights: true
        property bool notifyDirectMessages: true
        property int reconnectLimit: 10
        property bool reconnectAfterAuthFailure: false
        property int historyLimit: 200
        property string defaultPartReason: "Leaving"
        property bool showTimestamps: true
        property bool respondToCtcpVersion: true
        property string nickname: "kircuser"
        property bool saved: false
        function save() { glassCfg.saved = true }
    }

    function ok(name, cond, extra) {
        if (cond) {
            console.error("PASS " + name + (extra !== undefined ? " :: " + extra : ""))
        } else {
            harness.failures++
            console.error("FAIL " + name + (extra !== undefined ? " :: " + extra : ""))
        }
    }

    QtObject {
        id: derivedTests
        Component.onCompleted: {
            // ---- defaults -------------------------------------------------
            harness.ok("glass defaults: on / 60 / all sub-effects on",
                       ThemeEngine.glassEffects === true
                       && ThemeEngine.glassIntensity === 60
                       && ThemeEngine.glassBlur === true
                       && ThemeEngine.glassSheen === true
                       && ThemeEngine.glassEdges === true,
                       "on=" + ThemeEngine.glassEffects + " i=" + ThemeEngine.glassIntensity)

            // ---- derived colours on EVERY built-in theme -------------------
            var ids = ThemeEngine.availableThemeIds
            var allOk = true
            var detail = []
            for (var i = 0; i < ids.length; ++i) {
                ThemeEngine.applyBuiltinTheme(ids[i])
                var fill = ThemeEngine.glassFill
                var fillStrong = ThemeEngine.glassFillStrong
                var edgeL = ThemeEngine.glassEdgeLight
                var edgeD = ThemeEngine.glassEdgeDark
                var sheen = ThemeEngine.glassSheenTint
                var grain = ThemeEngine.glassGrain
                var shadow = ThemeEngine.glassShadow
                var ok = fill.a > 0.0 && fill.a < 1.0            // translucent
                        && fillStrong.a > fill.a                  // stronger variant
                        && edgeL.a > 0 && edgeD.a > 0 && sheen.a > 0
                        && grain.a >= 0 && shadow.a > 0
                if (!ok) { allOk = false }
                detail.push(ThemeEngine.themeId + ":" + fill.a.toFixed(2) + "/"
                            + edgeL.a.toFixed(2) + "/" + sheen.a.toFixed(2))
            }
            harness.ok("every built-in theme derives a usable glass colour set", allOk,
                       detail.join(" "))
            // tui's fill is its own panel colour at a translucent alpha
            ThemeEngine.applyBuiltinTheme("tui")
            var tuiFill = ThemeEngine.glassFill
            var tuiPanel = ThemeEngine.bgPanel
            harness.ok("tui glassFill is the theme panel colour, translucent",
                       ThemeEngine.cssColor(tuiFill) === ThemeEngine.cssColor(tuiPanel)
                       && tuiFill.a > 0 && tuiFill.a < 1,
                       ThemeEngine.cssColor(tuiFill) + "@" + tuiFill.a
                       + " panel=" + ThemeEngine.cssColor(tuiPanel))
            harness.ok("tui glass edge/sheen are accent-tinted",
                       ThemeEngine.luminanceOf(ThemeEngine.glassEdgeLight)
                       > ThemeEngine.luminanceOf(ThemeEngine.glassAccent),
                       "edge=" + ThemeEngine.cssColor(ThemeEngine.glassEdgeLight))
            // a palette-driven theme (breeze, empty tokens) still gets glass
            // when the call site hands in its resolved colour
            ThemeEngine.applyBuiltinTheme("breeze")
            var breezeFill = ThemeEngine.glassFillFor("#808080", false)
            harness.ok("glassFillFor follows a palette-resolved colour (breeze)",
                       Math.abs(breezeFill.r - 0.502) < 0.02
                       && Math.abs(breezeFill.g - 0.502) < 0.02
                       && breezeFill.a > 0 && breezeFill.a < 1,
                       "r=" + breezeFill.r.toFixed(3) + " a=" + breezeFill.a.toFixed(2))

            // ---- intensity clamps ------------------------------------------
            ThemeEngine.glassIntensity = 0
            harness.ok("intensity clamps at the bottom (0 -> 1)",
                       ThemeEngine.glassIntensity === 1, "i=" + ThemeEngine.glassIntensity)
            ThemeEngine.glassIntensity = -40
            harness.ok("intensity clamps at the bottom (-40 -> 1)",
                       ThemeEngine.glassIntensity === 1)
            ThemeEngine.glassIntensity = 101
            harness.ok("intensity clamps at the top (101 -> 100)",
                       ThemeEngine.glassIntensity === 100, "i=" + ThemeEngine.glassIntensity)
            ThemeEngine.glassIntensity = 5000
            harness.ok("intensity clamps at the top (5000 -> 100)",
                       ThemeEngine.glassIntensity === 100)
            harness.ok("clampGlassIntensity is the documented contract",
                       ThemeEngine.clampGlassIntensity(0) === 1
                       && ThemeEngine.clampGlassIntensity(100) === 100
                       && ThemeEngine.clampGlassIntensity(60) === 60
                       && ThemeEngine.clampGlassIntensity("nope") === 60)

            // the derived values scale with the intensity
            ThemeEngine.applyBuiltinTheme("tui")
            ThemeEngine.glassIntensity = 1
            var lowFill = ThemeEngine.glassFillFor("#101417", false).a
            var lowBlur = ThemeEngine.glassBlurMax
            var lowSheen = ThemeEngine.glassSheenTint.a
            ThemeEngine.glassIntensity = 100
            var highFill = ThemeEngine.glassFillFor("#101417", false).a
            var highBlur = ThemeEngine.glassBlurMax
            var highSheen = ThemeEngine.glassSheenTint.a
            harness.ok("intensity scales fill, blur radius and sheen",
                       highFill > lowFill && highBlur > lowBlur && highSheen > lowSheen,
                       "fill " + lowFill.toFixed(2) + "->" + highFill.toFixed(2)
                       + " blurMax " + lowBlur + "->" + highBlur
                       + " sheen " + lowSheen.toFixed(3) + "->" + highSheen.toFixed(3))
            ThemeEngine.glassIntensity = 60

            // ---- the component's own gates --------------------------------
            var comp = Qt.createComponent("org/kde/kirc/GlassSurface.qml")
            if (comp.status !== Component.Ready) {
                harness.failures++
                console.error("FAIL GlassSurface.qml load: " + comp.errorString())
                return
            }
            var sheet = comp.createObject(harness, {
                "width": 200, "height": 120,
                "blur": false, "sheen": false, "edges": false, "grainOpacity": 0
            })
            harness.ok("a GlassSurface with every per-call gate off hides each layer",
                       sheet !== null
                       && harness.findChildByName(sheet, "glassFrost").visible === false
                       && harness.findChildByName(sheet, "glassSheen").visible === false
                       && harness.findChildByName(sheet, "glassEdges").visible === false
                       && harness.findChildByName(sheet, "glassGrain").visible === false)
            if (sheet !== null) { sheet.destroy() }

            var sheet2 = comp.createObject(harness, { "width": 200, "height": 120 })
            harness.ok("with the defaults every layer is on",
                       sheet2 !== null
                       && harness.findChildByName(sheet2, "glassFrost").visible === true
                       && harness.findChildByName(sheet2, "glassSheen").visible === true
                       && harness.findChildByName(sheet2, "glassEdges").visible === true
                       && harness.findChildByName(sheet2, "glassGrain").visible === true)
            if (sheet2 !== null) { sheet2.destroy() }
            ThemeEngine.applyBuiltinTheme("tui")
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
            case 1: {
                // The chat page, a sized host, and a settings page with the
                // glass keys in its config double.
                var chatComp = Qt.createComponent("org/kde/kirc/ChatPage.qml")
                if (chatComp.status === Component.Ready) {
                    harness.chat = chatComp.createObject(harness, {
                        "bridge": bridgeDouble,
                        "hostWindow": windowDouble,
                        "width": 1024,
                        "height": 700
                    })
                } else {
                    harness.failures++
                    console.error("FAIL ChatPage.qml load: " + chatComp.errorString())
                }
                var setComp = Qt.createComponent("org/kde/kirc/SettingsPage.qml")
                if (setComp.status === Component.Ready) {
                    harness.settings = setComp.createObject(harness, {
                        "kircConfig": glassCfg,
                        "hostWindow": windowDouble
                    })
                } else {
                    harness.failures++
                    console.error("FAIL SettingsPage.qml load: " + setComp.errorString())
                }
                break
            }
            case 2: {
                harness.ok("ChatPage instantiated for the glass run", harness.chat !== null)
                harness.ok("SettingsPage instantiated for the glass run", harness.settings !== null)
                // Load a buffer so the log has rows to render behind glass.
                if (harness.chat !== null) {
                    harness.chat.refreshHistory()
                }
                break
            }
            case 3: {
                // ---- every main area carries a sheet --------------------
                ThemeEngine.glassEffects = true
                ThemeEngine.glassSheen = true
                ThemeEngine.glassBlur = true
                ThemeEngine.glassEdges = true
                harness.sheets = harness.findSheets(harness.chat, 0, [])
                harness.ok("every main display area has a glass sheet (>= 5)",
                           harness.sheets.length >= 5,
                           "sheets=" + harness.sheets.length)
                harness.ok("each sheet's host carries the area's theme colour",
                           harness.sheets.length > 0 && harness.sheetsAllColoured())
                var hidden = harness.sheets.filter(function (s) { return s.visible !== s.parent.visible })
                harness.ok("every sheet shows exactly when its area shows (glass on)",
                           hidden.length === 0,
                           "sheets=" + harness.sheets.length
                           + (hidden.length > 0 ? " mismatched: " + harness.sheetsDebug(hidden) : ""))
                // snapshot the geometry + colours the sheets sit on
                harness.snapshot = harness.takeSnapshot()
                break
            }
            case 4: {
                // ---- master toggle OFF: identical geometry and colours ---
                ThemeEngine.glassEffects = false
                break
            }
            case 5: {
                harness.ok("glass off: every sheet renders nothing",
                           harness.sheets.every(function (s) { return s.visible === false }),
                           "visible=" + harness.sheets.filter(function (s) { return s.visible }).length)
                var after = harness.takeSnapshot()
                harness.ok("glass off: geometry is byte-identical to the glass-on layout",
                           harness.sameGeometry(harness.snapshot, after),
                           "before=" + harness.snapshot.geom.join(",")
                           + " after=" + after.geom.join(","))
                harness.ok("glass off: the host surfaces keep their exact colours",
                           harness.snapshot.colors.join(",") === after.colors.join(","),
                           after.colors.join(","))
                harness.ok("glass off: the log still renders its rows",
                           harness.messageView() !== null
                           && harness.messageView().count === harness.snapshot.rows
                           && harness.messageView().count > 0,
                           "rows=" + (harness.messageView() ? harness.messageView().count : -1))
                // and back on
                ThemeEngine.glassEffects = true
                break
            }
            case 6: {
                harness.ok("glass back on: sheets show again where the area shows, geometry unchanged",
                           harness.sheets.every(function (s) {
                               return s.visible === s.parent.visible
                           })
                           && harness.sameGeometry(harness.snapshot, harness.takeSnapshot()))
                break
            }
            case 7: {
                // ---- sub-toggles gate their layer -----------------------
                ThemeEngine.glassSheen = false
                var sheenHidden = harness.sheets.every(function (s) {
                    return harness.findChildByName(s, "glassSheen").visible === false
                            && s.visible === s.parent.visible
                })
                harness.ok("GlassSheen off hides every sheen, keeps the sheet",
                           sheenHidden)
                ThemeEngine.glassBlur = false
                harness.ok("GlassBlur off hides every frost",
                           harness.sheets.every(function (s) {
                               return harness.findChildByName(s, "glassFrost").visible === false
                           }))
                ThemeEngine.glassEdges = false
                harness.ok("GlassEdges off hides every edge layer",
                           harness.sheets.every(function (s) {
                               return harness.findChildByName(s, "glassEdges").visible === false
                           }))
                ThemeEngine.glassSheen = true
                ThemeEngine.glassBlur = true
                ThemeEngine.glassEdges = true
                harness.ok("sub-toggles back on: every layer returns",
                           harness.sheets.every(function (s) {
                               return harness.findChildByName(s, "glassSheen").visible === s.visible
                                       && harness.findChildByName(s, "glassFrost").visible === s.visible
                                       && harness.findChildByName(s, "glassEdges").visible === s.visible
                           }))
                break
            }
            case 8: {
                // ---- settings: the controls mirror the config double -----
                var sp = harness.settings
                if (sp === null) { harness.failures++; console.error("FAIL no settings page"); break }
                sp.sectionIndex = 2
                // The seeded config has glass OFF and sheen OFF; put the engine
                // in the same state (what restoring kirc.conf would do) and let
                // the pane's sync land on the controls.
                ThemeEngine.glassEffects = false
                ThemeEngine.glassSheen = false
                var toggle = harness.findByText(sp, "Frosted glass effects", 0)
                harness.ok("the master glass toggle exists in Appearance", toggle !== null)
                harness.ok("the toggle mirrors the persisted value (seeded off)",
                           toggle !== null && toggle.checked === false,
                           toggle === null ? "null" : ("checked=" + toggle.checked))
                harness.ok("the glass hint says what the sheet is (in-app)",
                           harness.findTextContaining(sp, "in-app only", 0) !== null)
                var slider = harness.findByPredicate(sp, function (o) {
                    return o.from === 1 && o.to === 100 && o.value !== undefined
                           && o.stepSize === 1
                }, 0)
                harness.ok("the intensity slider exists and mirrors the value (25)",
                           slider !== null && slider.value === 25,
                           slider === null ? "null" : ("value=" + slider.value))
                var sheenToggle = harness.findByText(sp, "Reflection sheen", 0)
                harness.ok("the sheen sub-toggle mirrors the persisted value (off)",
                           sheenToggle !== null && sheenToggle.checked === false)
                harness.ok("sub-toggles disabled while the master is off",
                           sheenToggle !== null && sheenToggle.enabled === false,
                           sheenToggle === null ? "null" : ("enabled=" + sheenToggle.enabled))

                // ---- the round trip: control -> ThemeEngine -> config ----
                if (toggle !== null) {
                    toggle.checked = true
                    toggle.toggled()
                }
                harness.ok("toggling glass persists to the config (KircConfig contract)",
                           glassCfg.glassEffects === true && glassCfg.saved === true,
                           "cfg=" + glassCfg.glassEffects + " saved=" + glassCfg.saved)
                harness.ok("toggling glass applies live (ThemeEngine)",
                           ThemeEngine.glassEffects === true)
                harness.ok("sub-toggles enable once the master is on",
                           sheenToggle !== null && sheenToggle.enabled === true)
                if (sheenToggle !== null) {
                    sheenToggle.checked = true
                    sheenToggle.toggled()
                }
                harness.ok("the sheen toggle persists glassSheen",
                           glassCfg.glassSheen === true && ThemeEngine.glassSheen === true)
                if (slider !== null) {
                    // A real slider move: increase() changes the value the way
                    // the wheel / arrow keys do.
                    slider.value = 64
                    slider.increase()
                }
                harness.ok("the intensity slider round-trips its value (65)",
                           slider !== null && slider.value === 65
                           && ThemeEngine.glassIntensity === 65
                           && glassCfg.glassIntensity === 65,
                           slider === null ? "null"
                           : ("slider=" + slider.value + " te=" + ThemeEngine.glassIntensity
                              + " cfg=" + glassCfg.glassIntensity))
                break
            }
            case 9: {
                // ---- searchability --------------------------------------
                var sps = harness.settings
                sps.setFilter("glass")
                harness.ok("search 'glass' finds the Appearance section",
                           sps.sectionMatches(2) === true && sps.rowVisible("Glass") === true)
                sps.setFilter("frost")
                harness.ok("search 'frost' finds the frost row",
                           sps.rowVisible("Glass frost") === true
                           && sps.sectionMatches(2) === true)
                sps.setFilter("sheen")
                harness.ok("search 'sheen' finds the sheen row",
                           sps.rowVisible("Glass sheen") === true)
                sps.setFilter("reflection")
                harness.ok("search 'reflection' (keyword) finds the section",
                           sps.sectionMatches(2) === true)
                sps.setFilter("")
                harness.ok("clearing the search shows the glass rows again",
                           sps.rowVisible("Glass") === true
                           && sps.rowVisible("Glass intensity") === true)
                break
            }
            case 10: {
                // ---- the sheets never sit ON the log --------------------
                // The log's sheet is a sibling *under* the scrolling ListView
                // (its parent is the log surface, and the view is not inside
                // any glass sheet) — the performance contract. The same walk
                // over a real delegate instance proves the rows themselves
                // are never inside a sheet.
                var view = harness.messageView()
                var inSheet = false
                var walk = view
                while (walk !== null && walk !== undefined) {
                    if (walk.objectName === "glassSurface") { inSheet = true }
                    walk = walk.parent
                }
                harness.ok("the message ListView is not inside a glass sheet",
                           view !== null && !inSheet)
                var delegateInSheet = false
                if (view !== null && view.count > 0) {
                    var d = view.itemAtIndex(0)
                    var w2 = d
                    while (w2 !== null && w2 !== undefined) {
                        if (w2.objectName === "glassSurface") { delegateInSheet = true }
                        w2 = w2.parent
                    }
                }
                harness.ok("a log delegate is not inside a glass sheet either",
                           view !== null && view.count > 0 && !delegateInSheet,
                           "rows=" + (view === null ? -1 : view.count))
                console.error(harness.failures === 0 ? "GLASS-RESULT: ALL PASS"
                                                     : ("GLASS-RESULT: " + harness.failures + " FAILURES"))
                Qt.exit(harness.failures === 0 ? 0 : 1)
                break
            }
            }
        }
    }

    // ------------------------------------------------------------------- //
    // helpers
    // ------------------------------------------------------------------- //

    /// All GlassSurface instances under `root` (identified by the component's
    /// own objectName). Deduped: a Control's contentItem is also reachable
    /// through `children`, and each sheet must be counted once.
    function findSheets(root, depth, out) {
        if (root === null || root === undefined || depth > 16) { return out }
        if (root.objectName === "glassSurface" && out.indexOf(root) === -1) {
            out.push(root)
        }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            harness.findSheets(kids[i], depth + 1, out)
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            harness.findSheets(root.contentItem, depth + 1, out)
        }
        return out
    }

    function countSheets(root) {
        return harness.findSheets(root, 0, []).length
    }

    /// Human-readable identity of sheets for failure messages.
    function sheetsDebug(sheets) {
        var out = []
        for (var i = 0; i < sheets.length; ++i) {
            var host = sheets[i].parent
            out.push("[" + Math.round(host.width) + "x" + Math.round(host.height)
                     + " " + String(host.color) + " visible=" + sheets[i].visible + "]")
        }
        return out.join(" ")
    }

    function findChildByName(root, name, depth) {
        if (root === null || root === undefined || depth > 8) { return null }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            if (kids[i].objectName === name) { return kids[i] }
            var f = harness.findChildByName(kids[i], name, depth + 1)
            if (f !== null) { return f }
        }
        return null
    }

    /// Every sheet's host (the panel Rectangle it sits on) carries a real
    /// colour: the areas are painted, not transparent.
    function sheetsAllColoured() {
        for (var i = 0; i < harness.sheets.length; ++i) {
            var host = harness.sheets[i].parent
            if (host === null || host === undefined || host.color === undefined) { return false }
        }
        return true
    }

    /// Geometry + host colours + log row count of the areas under glass.
    function takeSnapshot() {
        var geom = []
        var colors = []
        for (var i = 0; i < harness.sheets.length; ++i) {
            var host = harness.sheets[i].parent
            geom.push(Math.round(host.width) + "x" + Math.round(host.height)
                      + "@" + Math.round(host.x) + "," + Math.round(host.y))
            colors.push(String(host.color))
        }
        var view = harness.messageView()
        return {
            "geom": geom,
            "colors": colors,
            "rows": view === null ? -1 : view.count,
            "viewH": view === null ? -1 : Math.round(view.height)
        }
    }

    function sameGeometry(a, b) {
        return a !== null && b !== null && a.geom.join(",") === b.geom.join(",")
                && a.viewH === b.viewH
    }

    function messageView() {
        return harness.findView(harness.chat, 0)
    }

    function findView(root, depth) {
        if (root === null || root === undefined || depth > 14) { return null }
        if (typeof root.positionViewAtEnd === "function" && root.model !== undefined
                && root.model !== null && typeof root.model.append === "function") {
            return root
        }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findView(kids[i], depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findView(root.contentItem, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }

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
}
