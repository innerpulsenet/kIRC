// Slash-command contract harness for ChatPage.qml.
//
// Loads the real ChatPage.qml (with the recording IrcBridge double from this
// module) and drives runSlash() with the exact lines a user types, asserting
// the bridge calls each one produces — the wire line for hand-built commands,
// the bridge invokable for the ones that have one — plus /help output, local
// lines, malformed-argument rejection and command tab-completion.
//
// Uses console.error because console.log is filtered by the qml runtime here.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: harness
    width: 1024
    height: 700

    property int failures: 0

    // Colour-free alias for the CTCP/ACTION marker built at run time (a
    // literal \u0001 in this file would be a real control byte).
    readonly property string ctl: String.fromCharCode(1)

    property var chat: chatLoader.item
    property var bridge: bridgeDouble
    property var window: windowDouble
    property var cfg: cfgDouble

    function ok(name, cond, extra) {
        if (cond) {
            console.error("PASS " + name + (extra !== undefined ? " :: " + extra : ""))
        } else {
            harness.failures++
            console.error("FAIL " + name + (extra !== undefined ? " :: " + extra : ""))
        }
    }

    Loader {
        id: chatLoader
        source: Qt.resolvedUrl("org/kde/kirc/ChatPage.qml")
        onStatusChanged: if (status === Loader.Error) { harness.failures++; console.error("FAIL ChatPage.qml load") }
    }

    IrcBridge { id: bridgeDouble }

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

    // ---- model access (the ListView whose model is the MessageListModel) ---
    function messageView() {
        return harness.findMessageView(harness.chat, 0)
    }
    function modelCount() {
        var v = harness.messageView()
        return v === null ? -1 : v.count
    }
    function rowText(index) {
        var v = harness.messageView()
        return (v === null || index < 0 || index >= v.count) ? "" : String(v.model.get(index).text)
    }

    // ---- one command = one asserted trace ---------------------------------
    /// Reset the active buffer (openChannel also records mark_read, which is
    /// cleared), run the exact command line, compare the recorded call trace.
    function wireCase(name, cmd, expectedTrace, expectConsumed) {
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        var consumed = harness.chat.runSlash(cmd)
        var trace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        harness.ok(name, trace === expectedTrace && consumed === expectConsumed,
                   "cmd=[" + cmd + "] consumed=" + consumed + " got=[" + trace + "] want=[" + expectedTrace + "]")
    }

    /// A command consumed locally: no bridge calls, exactly one local row.
    function localCase(name, cmd, expectConsumed, expectRowFragment) {
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        var before = harness.modelCount()
        var consumed = harness.chat.runSlash(cmd)
        var after = harness.modelCount()
        var trace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        var last = after > 0 ? harness.rowText(after - 1) : ""
        var rowOk = (after === before + 1)
                && (expectRowFragment === undefined || last.indexOf(expectRowFragment) !== -1)
        harness.ok(name, trace === "" && consumed === expectConsumed && rowOk,
                   "cmd=[" + cmd + "] consumed=" + consumed + " trace=[" + trace + "] rows "
                   + before + "->" + after + " last=[" + last + "]")
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
                harness.setup()
                break
            case 2:
                harness.runSuite()
                break
            }
        }
    }

    property int step: 0

    function setup() {
        harness.ok("ChatPage instantiated", harness.chat !== null)
        if (harness.chat === null) {
            harness.report()
            return
        }
        harness.chat.bridge = harness.bridge
        harness.chat.hostWindow = harness.window
        harness.bridge.nickname = "kircuser"
        harness.bridge.connected_server = "irc.test.example:6697"
        harness.bridge.connection_state = 2
        harness.chat.channels = ["*server*", "#kirc", "#kde", "alice"]
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        harness.ok("composer context is #kirc", harness.chat.currentChannel === "#kirc",
                   harness.chat.currentChannel)
    }

    function runSuite() {
        var C = harness.ctl
        var cases = [
            // ---- core IRC ------------------------------------------------- //
            ["join", "/join #kde", "join_channel(#kde)"],
            ["join with key", "/join #kde sekrit", "send_raw(JOIN #kde sekrit)"],
            ["join bare name gains #", "/join kde", "join_channel(#kde)"],
            ["part current", "/part", "part_channel(#kirc) mark_read()"],
            ["part with channel + reason", "/part #kde bye now", "send_raw(PART #kde :bye now)"],
            ["leave alias", "/leave #kde", "part_channel(#kde)"],
            ["wc alias", "/wc #kde", "part_channel(#kde)"],
            ["msg keeps multi-line text for the core's own split", "/msg alice line one\nline two",
             "mark_read() send_message(alice, line one\nline two)"],
            ["msg", "/msg alice hello there", "mark_read() send_message(alice, hello there)"],
            ["query", "/query alice", "mark_read()"],
            ["notice", "/notice alice hi there", "send_raw(NOTICE alice :hi there)"],
            ["me", "/me waves at everyone", "send_message(#kirc, " + C + "ACTION waves at everyone" + C + ")"],
            ["action alias", "/action waves", "send_message(#kirc, " + C + "ACTION waves" + C + ")"],
            ["nick", "/nick kircuser2", "send_raw(NICK kircuser2)"],
            ["topic set", "/topic new topic here", "send_raw(TOPIC #kirc :new topic here)"],
            ["topic query other channel", "/topic #kde", "send_raw(TOPIC #kde)"],
            ["kick", "/kick bob stop that", "send_raw(KICK #kirc bob :stop that)"],
            ["kick explicit channel + colon reason", "/kick #kde bob :stop", "send_raw(KICK #kde bob :stop)"],
            ["remove alias", "/remove bob", "send_raw(KICK #kirc bob)"],
            ["mode explicit target", "/mode #kde +o bob", "send_raw(MODE #kde +o bob)"],
            ["mode defaults to channel", "/mode +o bob", "send_raw(MODE #kirc +o bob)"],
            ["mode query", "/mode", "send_raw(MODE #kirc)"],
            ["op", "/op bob carol", "send_raw(MODE #kirc +o bob carol)"],
            ["deop", "/deop bob", "send_raw(MODE #kirc -o bob)"],
            ["voice", "/voice bob", "send_raw(MODE #kirc +v bob)"],
            ["devoice", "/devoice bob", "send_raw(MODE #kirc -v bob)"],
            ["halfop", "/halfop bob", "send_raw(MODE #kirc +h bob)"],
            ["dehalfop", "/dehalfop bob", "send_raw(MODE #kirc -h bob)"],
            ["whois", "/whois alice", "send_raw(WHOIS alice)"],
            ["whois two args", "/whois irc.test.example alice",
             "send_raw(WHOIS irc.test.example alice)"],
            ["whowas", "/whowas alice 5", "send_raw(WHOWAS alice 5)"],
            ["who current", "/who", "send_raw(WHO #kirc)"],
            ["who mask", "/who alice*", "send_raw(WHO alice*)"],
            ["names current", "/names", "send_raw(NAMES #kirc)"],
            ["names explicit", "/names #kde", "send_raw(NAMES #kde)"],
            ["list", "/list", "send_raw(LIST)"],
            ["list patterns", "/list #kde #kde-devel", "send_raw(LIST #kde,#kde-devel)"],
            ["motd", "/motd", "send_raw(MOTD)"],
            ["motd server", "/motd irc.test.example", "send_raw(MOTD irc.test.example)"],
            // /version with no argument stays the server VERSION command;
            // /version <nick> is the CTCP VERSION query shortcut.
            ["version alone is the server VERSION command", "/version", "send_raw(VERSION)"],
            ["version with a nick sends a CTCP VERSION query", "/version alice",
             "send_message(alice, " + C + "VERSION" + C + ")"],
            ["time", "/time", "send_raw(TIME)"],
            ["ping target", "/ping irc.test", "send_raw(PING :irc.test)"],
            ["ping defaults to server", "/ping", "send_raw(PING :irc.test.example)"],
            ["away", "/away lunch", "send_raw(AWAY :lunch)"],
            ["away no reason clears", "/away", "send_raw(AWAY)"],
            ["back", "/back", "send_raw(AWAY)"],
            ["invite default channel", "/invite bob", "send_raw(INVITE bob #kirc)"],
            ["invite explicit channel", "/invite bob #kde", "send_raw(INVITE bob #kde)"],
            ["oper", "/oper root hunter2", "send_raw(OPER root hunter2)"],
            ["userhost", "/userhost alice carol", "send_raw(USERHOST alice carol)"],
            ["ison", "/ison alice carol", "send_raw(ISON alice carol)"],
            ["setname", "/setname Real Name", "send_raw(SETNAME :Real Name)"],
            ["ctcp", "/ctcp alice version", "send_message(alice, " + C + "VERSION" + C + ")"],
            // ---- channel moderation --------------------------------------- //
            ["ban list", "/ban", "send_raw(MODE #kirc +b)"],
            ["ban nick expands", "/ban spammer", "send_raw(MODE #kirc +b spammer!*@*)"],
            ["ban mask as typed", "/ban *!*@spam.example", "send_raw(MODE #kirc +b *!*@spam.example)"],
            ["ban explicit channel", "/ban #kde spammer", "send_raw(MODE #kde +b spammer!*@*)"],
            ["unban", "/unban spammer", "send_raw(MODE #kirc -b spammer!*@*)"],
            ["kickban", "/kickban spammer bye",
             "send_raw(MODE #kirc +b spammer!*@*) send_raw(KICK #kirc spammer :bye)"],
            ["quiet", "/quiet spammer", "send_raw(MODE #kirc +q spammer!*@*)"],
            ["unquiet", "/unquiet spammer", "send_raw(MODE #kirc -q spammer!*@*)"],
            ["knock with message", "/knock #secret let me in", "send_raw(KNOCK #secret :let me in)"],
            ["knock plain", "/knock #secret", "send_raw(KNOCK #secret)"],
            // ---- IRCv3 ----------------------------------------------------- //
            ["chathistory default", "/chathistory", "request_history(#kirc, 200)"],
            ["chathistory target + count", "/chathistory #kde 50", "request_history(#kde, 50)"],
            ["markread", "/markread", "mark_read() send_raw(MARKREAD #kirc)"],
            ["monitor add list", "/monitor + alice bob", "send_raw(MONITOR + alice,bob)"],
            ["monitor remove", "/monitor - alice", "send_raw(MONITOR - alice)"],
            ["monitor bare nick adds", "/monitor alice", "send_raw(MONITOR + alice)"],
            ["monitor list", "/monitor list", "send_raw(MONITOR L)"],
            ["monitor status", "/monitor status", "send_raw(MONITOR S)"],
            ["account", "/account kircuser s3cret", "send_raw(PRIVMSG NickServ :IDENTIFY kircuser s3cret)"],
            ["cap end", "/cap end", "send_raw(CAP END)"],
            ["cap req colon list", "/cap req sasl chathistory", "send_raw(CAP REQ :sasl chathistory)"],
            ["cap ls passthrough", "/cap ls 302", "send_raw(CAP LS 302)"],
            ["batch passthrough", "/batch +xxx chathistory", "send_raw(BATCH +xxx chathistory)"],
            // ---- local / client ------------------------------------------- //
            ["clear", "/clear", "clear_buffer(#kirc)"],
            ["raw", "/raw WHOIS alice", "send_raw(WHOIS alice)"],
            ["quote alias", "/quote JOIN #channel", "send_raw(JOIN #channel)"],
            // ---- argument safety ------------------------------------------ //
            ["topic folds newline to one line", "/topic hello\nworld",
             "send_raw(TOPIC #kirc :hello world)"],
            ["notice folds newline to one line", "/notice alice one\ntwo",
             "send_raw(NOTICE alice :one two)"]
        ]
        for (var i = 0; i < cases.length; ++i) {
            harness.wireCase(cases[i][0], cases[i][1], cases[i][2], true)
        }

        // ---- malformed input is rejected locally, never on the wire ------ //
        harness.localCase("kick without a nick is rejected", "/kick", false, "usage: /kick")
        harness.localCase("monitor without args is rejected", "/monitor", false, "usage: /monitor")
        harness.localCase("oper without a password is rejected", "/oper root", false, "usage: /oper")
        harness.localCase("chathistory count 0 is rejected", "/chathistory #kde 0", false, "usage:")
        harness.localCase("whois on a channel is rejected", "/whois #kde", false, "usage: /whois")
        harness.localCase("unknown command prints a hint", "/frobnicate now", false, "unknown command")
        harness.localCase("raw with a newline is rejected", "/raw QUIT\nJOIN #evil", false, "/raw rejected")
        harness.localCase("empty raw is rejected", "/raw", false, "usage: /raw")
        harness.localCase("version with two targets is rejected", "/version alice bob", false, "usage: /version")

        // ---- /version <nick>: the query AND the local line -----------------
        // The CTCP trace is asserted in the case table above; this proves the
        // user is also told what was sent (one local row, nothing else).
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        var vBefore = harness.modelCount()
        var vConsumed = harness.chat.runSlash("/version alice")
        var vAfter = harness.modelCount()
        var vTrace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        var vRow = vAfter > 0 ? harness.rowText(vAfter - 1) : ""
        harness.ok("version <nick> says what it sent",
                   vConsumed === true && vTrace === ("send_message(alice, " + C + "VERSION" + C + ")")
                   && vAfter === vBefore + 1 && vRow.indexOf("CTCP VERSION query sent to alice") !== -1,
                   "trace=[" + vTrace + "] rows " + vBefore + "->" + vAfter + " last=[" + vRow + "]")

        // ---- /ctcp is unchanged (same query, no local chatter) -------------
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        var cBefore = harness.modelCount()
        var cConsumed = harness.chat.runSlash("/ctcp bob VERSION")
        var cAfter = harness.modelCount()
        var cTrace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        harness.ok("ctcp bob VERSION sends the same query without a local line",
                   cConsumed === true && cTrace === ("send_message(bob, " + C + "VERSION" + C + ")")
                   && cAfter === cBefore,
                   "trace=[" + cTrace + "] rows " + cBefore + "->" + cAfter)

        // ---- local lines ------------------------------------------------- //
        harness.localCase("echo prints a local line", "/echo hello world", true, "hello world")

        var helpRows = harness.chat.commandTable.length
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        var beforeHelp = harness.modelCount()
        var helpConsumed = harness.chat.runSlash("/help")
        var afterHelp = harness.modelCount()
        var helpTrace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        harness.ok("help prints every command", helpConsumed === true && helpTrace === ""
                   && afterHelp === beforeHelp + helpRows + 1,
                   "rows " + beforeHelp + "->" + afterHelp + " expected +" + (helpRows + 1))
        var helpText = ""
        for (var h = beforeHelp; h < afterHelp; ++h) {
            helpText += harness.rowText(h) + "\n"
        }
        harness.ok("help lists the modern set",
                   helpText.indexOf("/join") !== -1 && helpText.indexOf("/chathistory") !== -1
                   && helpText.indexOf("/markread") !== -1 && helpText.indexOf("/monitor") !== -1
                   && helpText.indexOf("/cap") !== -1 && helpText.indexOf("/setname") !== -1,
                   "rows=" + (afterHelp - beforeHelp))
        harness.ok("help rows carry a description",
                   helpText.indexOf("/ban [#channel] [mask|nick] — ban a mask or nick") !== -1,
                   "")
        harness.ok("help documents both /version forms on one line",
                   helpText.indexOf("/version [nick] — no nick: the server's VERSION; with a nick: send that client a CTCP VERSION query") !== -1,
                   "")
        harness.ok("help documents /ctcp as the general CTCP form",
                   helpText.indexOf("/ctcp <target> <message> — general CTCP query (e.g. /ctcp alice VERSION); /version <nick> is the shortcut") !== -1,
                   "")
        harness.localCase("help for one command", "/help chathistory", true, "/chathistory [target] [count]")
        harness.localCase("help for /version", "/help version", true, "/version [nick]")
        harness.localCase("help for /ctcp", "/help ctcp", true, "/ctcp <target> <message>")
        harness.localCase("help for an unknown command", "/help nope", false, "no such command")

        // ---- disconnect last (it resets the app state) -------------------- //
        harness.chat.openChannel("#kirc")
        harness.bridge.clearCalls()
        harness.window.userDisconnect = false
        var quitConsumed = harness.chat.runSlash("/quit bye")
        var quitTrace = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        harness.ok("quit sends the reason then disconnects",
                   quitConsumed === true && harness.window.userDisconnect === true
                   && quitTrace.indexOf("send_raw(QUIT :bye)") === 0
                   && quitTrace.indexOf("disconnect_server()") !== -1,
                   "trace=[" + quitTrace + "] userDisconnect=" + harness.window.userDisconnect)

        // ---- tab-completion ----------------------------------------------- //
        harness.chat.nickList = ["alice", "bob", "carol"]
        var comp

        comp = harness.chat.nextCompletion("/jo", 3)
        harness.ok("command completes: /jo -> /join ", comp !== null && comp.text === "/join " && comp.cursor === 6,
                   comp === null ? "null" : ("text=[" + comp.text + "] cursor=" + comp.cursor))

        comp = harness.chat.nextCompletion("/pa", 3)
        harness.ok("command completes: /pa -> /part ", comp !== null && comp.text === "/part ",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("/help", 5)
        harness.ok("command completes uniquely", comp !== null && comp.text === "/help ",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("/ver", 4)
        harness.ok("command completes: /ver -> /version ", comp !== null && comp.text === "/version ",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("/le", 3)
        harness.ok("alias completes: /le -> /leave ", comp !== null && comp.text === "/leave ",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("/", 1)
        harness.ok("bare / offers commands", comp !== null && comp.text.charAt(0) === "/"
                   && comp.text.length > 1 && comp.cursor === comp.text.length,
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("al", 2)
        harness.ok("nick completion at line start keeps \": \"", comp !== null && comp.text === "alice: ",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("hi al", 5)
        harness.ok("nick completion mid-line unchanged", comp !== null && comp.text === "hi alice",
                   comp === null ? "null" : comp.text)

        comp = harness.chat.nextCompletion("hi /jo", 6)
        harness.ok("commands do not complete mid-line", comp === null)

        comp = harness.chat.nextCompletion("/zzz", 4)
        harness.ok("unknown /word does not complete", comp === null)

        // End-to-end through the real composer: Tab drives tabComplete().
        var input = harness.findInput(harness.chat, 0)
        harness.ok("composer input found", input !== null)
        if (input !== null) {
            input.text = "/ch"
            input.cursorPosition = 3
            harness.chat.tabComplete()
            harness.ok("Tab completes /ch to /chathistory in the composer",
                       input.text === "/chathistory " && input.cursorPosition === 13,
                       "text=[" + input.text + "] cursor=" + input.cursorPosition)
        }

        harness.report()
    }

    function report() {
        console.error(harness.failures === 0 ? "CMDS-RESULT: ALL PASS" : ("CMDS-RESULT: " + harness.failures + " FAILURES"))
        Qt.exit(harness.failures === 0 ? 0 : 1)
    }

    // Depth-first search for the composer (the only control with
    // selectByMouse explicitly enabled).
    function findInput(root, depth) {
        if (root === null || root === undefined || depth > 16) { return null }
        if (root.selectByMouse === true && typeof root.forceActiveFocus === "function") {
            return root
        }
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var f = harness.findInput(kids[i], depth + 1)
            if (f !== null) { return f }
        }
        if (root.contentItem !== undefined && root.contentItem !== null) {
            var c = harness.findInput(root.contentItem, depth + 1)
            if (c !== null) { return c }
        }
        return null
    }

    // Depth-first search for the message ListView: the only ListView whose
    // model is the MessageListModel (the sidebar's model is a plain array).
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
