// Position-based harness for ChatPage's follow-the-tail autoscroll.
//
// Loads the real ChatPage.qml (with the IrcBridge / MessageListModel doubles
// from this module) into a sized item, drives live traffic through the real
// bridge signal, and asserts on POSITIONS — never on appearances.
//
// What it proves:
//
//   1. FOLLOWING — after opening a long buffer, K appends (each delivered as
//      a real `message_received` signal) keep the view pinned at the tail:
//      the last row's delegate bottom stays flush with the viewport bottom
//      (within the code's tolerance) after every single append, and the
//      drift never accumulates.  A tall wrapped row — one whose delegate
//      height only resolves AFTER insertion — is included: the re-pin on
//      content-height changes must land the view flush again.
//   2. SCROLLED UP — moving the view up (an unguarded contentY change, i.e.
//      what a drag / flick / wheel ending away from the tail does) stops
//      following; an append then leaves contentY byte-identical and the
//      "[ new messages ]" pill is shown.  A real kinetic `flick()` gesture
//      is included, and the same no-yank/no-move assertions are made for it.
//   3. RECOVERY — clicking the pill, or scrolling back to the end, re-arms
//      following: the next append moves the view and lands flush again.
//   4. BUFFER SWITCH — switching buffers lands at the bottom with following
//      re-armed, and appends in the new buffer follow; a disconnect resets
//      to the server console and follows again.  Our own echo still pins
//      (the long-standing contract for one's own line) and re-arms following.
//
// The "pinned" metric is position-based, because in this headless harness the
// ListView's contentHeight estimate can disagree with the real delegate
// positions while rows are unmeasured:
//
//     gap = (lastDelegate.y + lastDelegate.height) - (contentY + view.height)
//
// gap 0  = the last row's bottom sits exactly at the viewport bottom edge
// gap >0 = the tail is hidden below the fold (the bug's signature)
//
// Uses console.error because console.log is filtered by the qml runtime here.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: harness
    width: 1100
    height: 800

    property int failures: 0
    property var chat: chatLoader.item
    property var view: null
    property string phase: "start"

    // Position tolerance: the app's own tailTolerance is 6px (rowHt 24 / 4),
    // so snapping back must land well inside it; a strict 2px proves the pin
    // is flush, not merely "close enough".
    readonly property real gapTolerance: 2

    // Number of short live appends in the follow-the-tail run.
    readonly property int shortAppends: 8

    property var gaps: []
    property int appendIndex: 0
    property real cyBefore: 0
    property var pill: null

    // Settle machinery: polls until (contentY, contentHeight, count, view
    // height) are unchanged for a few consecutive frames AND the flickable is
    // no longer moving/flicking, so every assertion reads a layout that has
    // come to rest — including the deferred height resolution of a freshly
    // inserted delegate and a kinetic flick's momentum.
    property var settleFn: null
    property int settleStable: 0
    property int settleTicks: 0
    property real lastCy: -1e9
    property real lastCh: -1e9
    property real lastVh: -1e9
    property int lastCount: -1
    property int settleTimeouts: 0

    Loader {
        id: chatLoader
        anchors.fill: parent
        source: Qt.resolvedUrl("org/kde/kirc/ChatPage.qml")
        onStatusChanged: if (status === Loader.Error) {
            harness.failures++
            console.error("FAIL ChatPage.qml load")
        }
    }

    IrcBridge { id: bridge }

    QtObject {
        id: cfgDouble
        property int historyLimit: 200
        property bool identifyOnConnect: false
        property string autojoin: ""
        property string nickname: "kircuser"
        property string nickservNick: ""
        property string nickservPassword: ""
    }

    QtObject {
        id: windowDouble
        property var appConfig: cfgDouble
        property string chatChannel: "*server*"
        property bool userDisconnect: false
    }

    function ok(name, cond, extra) {
        if (cond) {
            console.error("PASS " + name + (extra !== undefined ? " :: " + extra : ""))
        } else {
            harness.failures++
            console.error("FAIL " + name + (extra !== undefined ? " :: " + extra : ""))
        }
    }

    Timer {
        id: watchdog
        interval: 60000
        running: true
        repeat: false
        onTriggered: {
            console.error("SCROLL watchdog: stuck in phase " + harness.phase
                          + " (count=" + (harness.view ? harness.view.count : -1) + ")")
            console.error("SCROLL-RESULT: STUCK")
            Qt.exit(2)
        }
    }

    Timer {
        id: settler
        interval: 16
        repeat: true
        onTriggered: harness.settleTick()
    }

    function waitSettle(fn) {
        harness.settleFn = fn
        harness.settleStable = 0
        harness.settleTicks = 0
        harness.lastCy = -1e9
        harness.lastCh = -1e9
        harness.lastVh = -1e9
        harness.lastCount = -1
        settler.restart()
    }

    function settleTick() {
        harness.settleTicks += 1
        var v = harness.view
        if (v !== null
                && !v.moving && !v.flicking
                && Math.abs(v.contentY - harness.lastCy) < 0.01
                && Math.abs(v.contentHeight - harness.lastCh) < 0.01
                && Math.abs(v.height - harness.lastVh) < 0.01
                && v.count === harness.lastCount) {
            harness.settleStable += 1
        } else {
            harness.settleStable = 0
        }
        if (v !== null) {
            harness.lastCy = v.contentY
            harness.lastCh = v.contentHeight
            harness.lastVh = v.height
            harness.lastCount = v.count
        }
        if (harness.settleStable >= 4 || harness.settleTicks > 120) {
            settler.stop()
            if (harness.settleStable < 4) {
                harness.settleTimeouts += 1
                console.error("SCROLL note: a settle poll timed out in phase " + harness.phase)
            }
            var fn = harness.settleFn
            harness.settleFn = null
            if (fn !== null) {
                fn()
            }
        }
    }

    Component.onCompleted: Qt.callLater(harness.setup)

    // ---- helpers ---------------------------------------------------------- //

    /// The distance the tail's bottom edge sits below the viewport bottom:
    /// 0 = flush with the end, >0 = the tail is hidden below the fold.
    function tailGap() {
        var v = harness.view
        if (v === null || v.count === 0) {
            return 0
        }
        var last = v.itemAtIndex(v.count - 1)
        if (last === null) {
            return 1e9
        }
        return (last.y + last.height) - (v.contentY + v.height)
    }

    function pinned() {
        var gap = harness.tailGap()
        return gap <= harness.gapTolerance && gap >= -harness.gapTolerance
    }

    /// `tailGap()` for messages: the sentinel means the tail delegate does
    /// not exist at all (the view is far away from it).
    function gapText() {
        var gap = harness.tailGap()
        return gap === 1e9 ? "n/a (tail not instantiated)" : String(gap)
    }

    function longText() {
        var s = ""
        for (var i = 0; i < 220; ++i) {
            s += "wrapped word" + i + " "
        }
        return s
    }

    // Depth-first search for the message ListView (same rule as tst_smoke).
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

    /// Depth-first search for a control whose `text` matches exactly.
    function findByText(root, text, depth) {
        if (root === null || root === undefined || depth > 18) { return null }
        if (root.text === text) { return root }
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

    function completelyVisible(item) {
        var it = item
        while (it !== null && it !== undefined) {
            if (it.visible === false) { return false }
            it = it.parent
        }
        return true
    }

    // ---- phases ----------------------------------------------------------- //

    function setup() {
        harness.phase = "setup"
        harness.ok("ChatPage instantiated", harness.chat !== null)
        if (harness.chat === null) { harness.report(); return }
        harness.chat.bridge = bridge
        harness.chat.hostWindow = windowDouble
        bridge.nickname = "kircuser"
        bridge.connected_server = "irc.test.example:6697"
        bridge.connection_state = 2
        harness.chat.channels = ["*server*", "#scroll", "#other"]

        harness.view = harness.findMessageView(harness.chat, 0)
        harness.ok("message ListView found", harness.view !== null)
        if (harness.view === null) { harness.report(); return }
        harness.ok("message view has a real size",
                   harness.view.width > 0 && harness.view.height > 0,
                   "w=" + harness.view.width + " h=" + harness.view.height)
        harness.ok("following starts armed", harness.chat.followTail === true)

        // A long transcript through the real open path.
        harness.phase = "open-buffer"
        harness.view.model.syntheticRowCount = 240
        harness.chat.openChannel("#scroll")
        harness.waitSettle(harness.checkOpenedAtBottom)
    }

    function checkOpenedAtBottom() {
        harness.ok("opening a long buffer lands at the bottom",
                   harness.view.count > 20 && harness.pinned(),
                   "count=" + harness.view.count + " gap=" + harness.gapText())
        harness.ok("opening a buffer re-armed following", harness.chat.followTail === true)
        harness.ok("no unseen pill after opening", harness.chat.hasUnseenBelow === false)
        harness.startAppendRun()
    }

    // ---- 1. following: K appends, no drift -------------------------------- //

    function startAppendRun() {
        harness.phase = "append-run"
        harness.gaps = []
        harness.appendIndex = 0
        harness.appendOne()
    }

    function appendOne() {
        bridge.message_received("#scroll", "flood" + (harness.appendIndex % 7),
                                "live line " + harness.appendIndex
                                + " with enough words to wrap once in a while",
                                "13:0" + (harness.appendIndex % 10), false, false)
        harness.waitSettle(harness.checkAppendedOne)
    }

    function checkAppendedOne() {
        var gap = harness.tailGap()
        harness.gaps.push(gap)
        harness.ok("append #" + harness.appendIndex + " stays pinned at the tail",
                   harness.pinned(),
                   "gap=" + gap + " contentY=" + harness.view.contentY
                   + " count=" + harness.view.count)
        harness.appendIndex += 1
        if (harness.appendIndex < harness.shortAppends) {
            harness.appendOne()
            return
        }
        var maxGap = -1e9
        var maxAbs = 0
        for (var i = 0; i < harness.gaps.length; ++i) {
            if (harness.gaps[i] > maxGap) { maxGap = harness.gaps[i] }
            if (Math.abs(harness.gaps[i]) > maxAbs) { maxAbs = Math.abs(harness.gaps[i]) }
        }
        harness.ok("no cumulative drift across " + harness.shortAppends + " appends",
                   maxAbs <= harness.gapTolerance,
                   "maxAbsGap=" + maxAbs + " gaps=[" + harness.gaps.join(",") + "]")
        harness.longRowCase()
    }

    // ---- the delegate height that resolves after insertion ---------------- //

    function longRowCase() {
        harness.phase = "long-row"
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#scroll", "flood3", harness.longText(), "13:20", false, false)
        harness.waitSettle(harness.checkLongRow)
    }

    function checkLongRow() {
        var gap = harness.tailGap()
        harness.ok("a row whose height resolves after insertion stays pinned",
                   harness.view.count > 0 && harness.pinned(),
                   "gap=" + gap + " contentY=" + harness.view.contentY
                   + " contentHeight=" + harness.view.contentHeight)
        harness.ok("the view followed the tall row down",
                   harness.view.contentY > harness.cyBefore + 100,
                   "contentY " + harness.cyBefore + " -> " + harness.view.contentY)

        bridge.message_received("#scroll", "flood4", "after the tall row", "13:21", false, false)
        harness.waitSettle(harness.checkAfterLongAppend)
    }

    function checkAfterLongAppend() {
        var gap = harness.tailGap()
        harness.ok("still following after the tall row",
                   harness.pinned() && harness.chat.followTail === true,
                   "gap=" + gap + " followTail=" + harness.chat.followTail)
        harness.scrollUpCase()
    }

    // ---- 2. scrolled up: no yank, pill shown ------------------------------ //

    function scrollUpCase() {
        harness.phase = "scroll-up"
        // What a drag / flick / wheel ending away from the tail does: the
        // view moves off the end without any help from this page.
        harness.view.contentY = Math.max(0, harness.view.contentY - 500)
        harness.waitSettle(harness.checkScrolledUp)
    }

    function checkScrolledUp() {
        harness.ok("moving the view up stops following",
                   harness.chat.followTail === false,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        harness.ok("the view really is away from the tail",
                   !harness.pinned(),
                   "gap=" + harness.gapText())
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#scroll", "flood5", "while the user reads back", "13:30", false, false)
        harness.waitSettle(harness.checkNoYank)
    }

    function checkNoYank() {
        harness.ok("an append while scrolled up does not move the view",
                   Math.abs(harness.view.contentY - harness.cyBefore) < 0.5,
                   "before=" + harness.cyBefore + " after=" + harness.view.contentY)
        harness.ok("an append while scrolled up raises hasUnseenBelow",
                   harness.chat.hasUnseenBelow === true)
        harness.pill = harness.findByText(harness.chat, "[ new messages ]", 0)
        harness.ok("the [ new messages ] pill is shown",
                   harness.pill !== null && harness.pill.visible === true
                   && harness.completelyVisible(harness.pill))
        harness.pillClickCase()
    }

    // ---- 3. recovery: pill click and manual return ------------------------ //

    function pillClickCase() {
        harness.phase = "pill-click"
        if (harness.pill === null) {
            harness.manualReturnCase()
            return
        }
        harness.pill.clicked()
        harness.waitSettle(harness.checkPillRecovered)
    }

    function checkPillRecovered() {
        harness.ok("clicking the pill returns to the tail and re-arms following",
                   harness.chat.followTail === true && harness.pinned()
                   && harness.chat.hasUnseenBelow === false,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#scroll", "flood6", "after the pill recovery", "13:31", false, false)
        harness.waitSettle(harness.checkFollowsAfterPill)
    }

    function checkFollowsAfterPill() {
        harness.ok("appends follow again after the pill recovery",
                   harness.pinned() && harness.view.contentY > harness.cyBefore,
                   "gap=" + harness.gapText() + " contentY " + harness.cyBefore
                   + " -> " + harness.view.contentY)
        harness.manualReturnCase()
    }

    function manualReturnCase() {
        harness.phase = "manual-return"
        harness.view.contentY = Math.max(0, harness.view.contentY - 600)
        harness.waitSettle(harness.checkAwayAgain)
    }

    function checkAwayAgain() {
        harness.ok("scrolling up again stops following",
                   harness.chat.followTail === false,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        // Return to the end the way a user scrolling back down does.
        harness.view.contentY = Math.max(0, harness.view.contentHeight - harness.view.height)
        harness.waitSettle(harness.checkBackAtTail)
    }

    function checkBackAtTail() {
        harness.ok("returning to the end resumes following",
                   harness.chat.followTail === true,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#scroll", "flood0", "after the manual return", "13:32", false, false)
        harness.waitSettle(harness.checkFollowsAfterReturn)
    }

    function checkFollowsAfterReturn() {
        harness.ok("appends follow again after the manual return",
                   harness.pinned() && harness.view.contentY > harness.cyBefore,
                   "gap=" + harness.gapText() + " contentY " + harness.cyBefore
                   + " -> " + harness.view.contentY)
        harness.flickAwayCase()
    }

    // ---- a real flick gesture ending away from the tail ------------------- //

    function flickAwayCase() {
        harness.phase = "flick-away"
        // A real kinetic gesture: +y flick velocity screens toward older
        // rows.  The gesture must stop following and must not be fought by
        // a re-pin.
        harness.view.flick(0, 12000)
        harness.waitSettle(harness.checkFlickAway)
    }

    function checkFlickAway() {
        harness.ok("a flick ending away from the tail stops following",
                   harness.chat.followTail === false && !harness.pinned(),
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText()
                   + " contentY=" + harness.view.contentY)
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#scroll", "flood7", "while the user flicked away", "13:35", false, false)
        harness.waitSettle(harness.checkFlickNoYank)
    }

    function checkFlickNoYank() {
        harness.ok("an append after the flick does not move the view",
                   Math.abs(harness.view.contentY - harness.cyBefore) < 0.5,
                   "before=" + harness.cyBefore + " after=" + harness.view.contentY)
        harness.ok("an append after the flick raises the pill",
                   harness.chat.hasUnseenBelow === true)
        harness.bufferSwitchCase()
    }

    // ---- 4. buffer switch + disconnect reset ------------------------------ //

    function bufferSwitchCase() {
        harness.phase = "buffer-switch"
        harness.chat.openChannel("#other")
        harness.waitSettle(harness.checkSwitched)
    }

    function checkSwitched() {
        harness.ok("switching buffers lands at the bottom",
                   harness.view.count > 20 && harness.pinned(),
                   "count=" + harness.view.count + " gap=" + harness.gapText())
        harness.ok("switching buffers re-armed following",
                   harness.chat.followTail === true && harness.chat.hasUnseenBelow === false,
                   "followTail=" + harness.chat.followTail)
        harness.cyBefore = harness.view.contentY
        bridge.message_received("#other", "flood1", "first line in the other buffer", "13:40", false, false)
        harness.waitSettle(harness.checkOtherFollows)
    }

    function checkOtherFollows() {
        harness.ok("appends in the switched-to buffer follow",
                   harness.pinned() && harness.view.contentY > harness.cyBefore,
                   "gap=" + harness.gapText() + " contentY " + harness.cyBefore
                   + " -> " + harness.view.contentY)
        harness.disconnectCase()
    }

    function disconnectCase() {
        harness.phase = "disconnect"
        bridge.disconnect_server()
        harness.waitSettle(harness.checkReset)
    }

    function checkReset() {
        harness.ok("disconnect resets to the server console and re-arms following",
                   harness.chat.currentChannel === "*server*" && harness.chat.followTail === true,
                   "channel=" + harness.chat.currentChannel + " followTail=" + harness.chat.followTail)
        harness.cyBefore = harness.view.contentY
        bridge.message_received("*server*", "*", "console line after the reset", "13:50", false, false)
        harness.waitSettle(harness.checkResetFollows)
    }

    function checkResetFollows() {
        harness.ok("appends follow after the disconnect reset",
                   harness.pinned() && harness.view.contentY > harness.cyBefore,
                   "gap=" + harness.gapText() + " contentY " + harness.cyBefore
                   + " -> " + harness.view.contentY)
        harness.selfEchoCase()
    }

    // ---- our own echo is always shown ------------------------------------- //

    function selfEchoCase() {
        harness.phase = "self-echo"
        // Scroll away, then send our own line: the echo must be shown (the
        // long-standing contract for one's own message) and following
        // resumes from it.
        harness.view.contentY = Math.max(0, harness.view.contentY - 400)
        harness.waitSettle(harness.checkEchoAway)
    }

    function checkEchoAway() {
        harness.ok("scrolling up before the echo stops following",
                   harness.chat.followTail === false,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        bridge.message_received("*server*", "kircuser", "my own line", "13:51", true, false)
        harness.waitSettle(harness.checkEchoShown)
    }

    function checkEchoShown() {
        harness.ok("our own echo is pinned and following resumes",
                   harness.chat.followTail === true && harness.pinned()
                   && harness.chat.hasUnseenBelow === false,
                   "followTail=" + harness.chat.followTail + " gap=" + harness.gapText())
        harness.report()
    }

    function report() {
        harness.ok("every settle poll came to rest",
                   harness.settleTimeouts === 0,
                   "timeouts=" + harness.settleTimeouts)
        console.error(harness.failures === 0 ? "SCROLL-RESULT: ALL PASS"
                                             : ("SCROLL-RESULT: " + harness.failures + " FAILURES"))
        Qt.exit(harness.failures === 0 ? 0 : 1)
    }
}
