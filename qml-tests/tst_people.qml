// People-panel contract harness for ChatPage.qml.
//
// Loads the real ChatPage.qml (with the recording IrcBridge double from this
// module) and asserts the user-list behaviour: a single click only selects,
// private chat is an explicit menu action, op/voice/kick/ban are gated on
// our own rank and never act on self, the WHOIS dialog captures its reply
// lines, and channel properties build the right TOPIC/MODE lines.
//
// Uses console.error because console.log is filtered by the qml runtime here.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: harness
    width: 1024
    height: 700

    property int failures: 0

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
        property string nickname: "me"
        property string nickservNick: ""
        property string nickservPassword: ""
    }

    QtObject {
        id: windowDouble
        property var appConfig: cfgDouble
        property string chatChannel: "*server*"
        property bool userDisconnect: false
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
        harness.bridge.nickname = "me"
        harness.bridge.connected_server = "irc.test.example:6697"
        harness.bridge.connection_state = 2
        harness.chat.channels = ["*server*", "#chan"]
        harness.chat.openChannel("#chan")
        // We are an operator here; bob is voiced, carol plain.
        harness.bridge.names_updated("#chan", "@me +bob carol")
        harness.bridge.clearCalls()
        harness.ok("people setup on #chan", harness.chat.currentChannel === "#chan"
                   && harness.chat.nickList.length === 3,
                   "chan=" + harness.chat.currentChannel + " nicks=" + harness.chat.nickList.join(","))
    }

    /// The bridge trace since the last clear, then cleared.
    function trace() {
        var t = harness.bridge.callTrace()
        harness.bridge.clearCalls()
        return t
    }

    /// openChannel reloads the nick list from the bridge double, so every
    /// return to #chan re-establishes our operator entry afterwards.
    function joinChan() {
        harness.chat.openChannel("#chan")
        harness.bridge.names_updated("#chan", "@me +bob carol")
        harness.bridge.clearCalls()
    }

    function runSuite() {
        // ---- single click selects, never opens -------------------------- //
        harness.joinChan()
        harness.chat.selectPerson("bob")
        harness.ok("select highlights only", harness.chat.selectedNick === "bob"
                   && harness.chat.currentChannel === "#chan" && harness.trace() === "",
                   "sel=" + harness.chat.selectedNick + " chan=" + harness.chat.currentChannel)

        // ---- rank gating ------------------------------------------------- //
        harness.ok("op self is manageable", harness.chat.canManage("#chan") === true)
        harness.ok("own rank is operator", harness.chat.ownRankIn("#chan") === 1,
                   "rank=" + harness.chat.ownRankIn("#chan"))
        harness.bridge.names_updated("#chan", "me +bob carol")
        harness.ok("rankless self cannot manage", harness.chat.canManage("#chan") === false
                   && harness.chat.ownRankIn("#chan") === 4)
        harness.bridge.names_updated("#chan", "@me +bob carol")

        // ---- privilege changes ------------------------------------------- //
        harness.chat.menuChannel = "#chan"
        var r = harness.chat.personAction("+o", "bob")
        harness.ok("op sends MODE +o", r === true && harness.trace() === "send_raw(MODE #chan +o bob)")
        r = harness.chat.personAction("-o", "bob")
        harness.ok("deop sends MODE -o", r === true && harness.trace() === "send_raw(MODE #chan -o bob)")
        r = harness.chat.personAction("+v", "carol")
        harness.ok("voice sends MODE +v", r === true && harness.trace() === "send_raw(MODE #chan +v carol)")
        r = harness.chat.personAction("-v", "bob")
        harness.ok("devoice sends MODE -v", r === true && harness.trace() === "send_raw(MODE #chan -v bob)")
        r = harness.chat.personAction("+o", "me")
        harness.ok("no privilege change on self", r === false && harness.trace() === "")
        harness.bridge.names_updated("#chan", "me +bob carol")
        r = harness.chat.personAction("+o", "bob")
        harness.ok("rankless self is refused", r === false && harness.trace() === "")
        harness.bridge.names_updated("#chan", "@me +bob carol")

        // ---- kick / ban builders ------------------------------------------ //
        harness.chat.kickNick("#chan", "bob", "spam")
        harness.ok("kick with reason", harness.trace() === "send_raw(KICK #chan bob :spam)")
        harness.chat.kickNick("#chan", "bob", "")
        harness.ok("kick without reason", harness.trace() === "send_raw(KICK #chan bob)")
        harness.chat.banNick("#chan", "bob!*@*")
        harness.ok("ban mask", harness.trace() === "send_raw(MODE #chan +b bob!*@*)")
        harness.ok("ban prefill expands a bare nick", harness.chat.banMask("bob") === "bob!*@*")

        // ---- private message is explicit ---------------------------------- //
        harness.joinChan()
        r = harness.chat.personAction("pm", "bob")
        harness.ok("pm opens the query", r === true && harness.chat.currentChannel === "bob",
                   "chan=" + harness.chat.currentChannel)
        harness.chat.openChannel("#chan")
        harness.trace()
        r = harness.chat.personAction("pm", "me")
        harness.ok("no pm to self", r === false && harness.chat.currentChannel === "#chan")

        // ---- WHOIS dialog capture ------------------------------------------ //
        harness.chat.openChannel("#chan")
        harness.trace()
        harness.chat.openWhois("alice")
        harness.ok("whois asks the server", harness.trace() === "send_raw(WHOIS alice)"
                   && harness.chat.whoisNick === "alice" && harness.chat.whoisCollecting === true)
        harness.bridge.message_received("#chan", "*", "311 alice ident h * :Alice Example", "12:00", false, false)
        harness.bridge.message_received("#chan", "*", "319 alice :#chan #other", "12:00", false, false)
        harness.bridge.message_received("#chan", "*", "311 mallory x y * :Someone else", "12:00", false, false)
        harness.bridge.message_received("#chan", "*", "372 - some motd line", "12:00", false, false)
        harness.ok("whois captures its own lines only", harness.chat.whoisLines.length === 2
                   && harness.chat.whoisLines[0].label === "User"
                   && harness.chat.whoisLines[1].label === "Channels"
                   && harness.chat.whoisCollecting === true,
                   "lines=" + JSON.stringify(harness.chat.whoisLines))
        harness.bridge.message_received("#chan", "*", "318 alice :End of WHOIS list", "12:00", false, false)
        harness.ok("318 closes the capture", harness.chat.whoisCollecting === false
                   && harness.chat.whoisDone === true && harness.chat.whoisLines.length === 3)

        // ---- channel properties --------------------------------------------- //
        harness.ok("props target the channel", (harness.chat.openChannelProperties("#chan"), harness.chat.propChannel) === "#chan"
                   && harness.chat.propInitialTopic === "kIRC development",
                   "topic=" + harness.chat.propInitialTopic)
        harness.ok("props query the live modes", harness.trace() === "send_raw(MODE #chan)")
        var sent = harness.chat.applyChannelProperties("#chan", "new topic", "kIRC development", "", "")
        harness.ok("topic change sends TOPIC", sent === true
                   && harness.trace() === "send_raw(TOPIC #chan :new topic)")
        sent = harness.chat.applyChannelProperties("#chan", "kIRC development", "kIRC development", "", "")
        harness.ok("unchanged topic sends nothing", sent === false && harness.trace() === "")
        sent = harness.chat.applyChannelProperties("#chan", "", "old topic", "", "")
        harness.ok("cleared topic clears", sent === true && harness.trace() === "send_raw(TOPIC #chan :)")
        sent = harness.chat.applyChannelProperties("#chan", "t", "t", "i", "m")
        harness.ok("modes combine into one MODE", sent === true
                   && harness.trace() === "send_raw(MODE #chan +i-m)")
        sent = harness.chat.applyChannelProperties("alice", "t", "t", "i", "")
        harness.ok("props refuse a query", sent === false && harness.trace() === "")

        // ---- server-confirmed modes -------------------------------------- //
        harness.chat.openChannelProperties("#chan")
        harness.trace()
        harness.ok("props start half-marked",
                   harness.chat.propModeState("i") === Qt.PartiallyChecked
                   && harness.chat.propModeState("m") === Qt.PartiallyChecked
                   && harness.chat.propModeState("n") === Qt.PartiallyChecked
                   && harness.chat.propModeState("t") === Qt.PartiallyChecked)
        // The user checks n before any reply arrives.
        harness.chat.setPropMode("n", Qt.Checked)
        harness.bridge.channel_modes_changed("#chan", "im")
        harness.ok("modes fill untouched boxes only",
                   harness.chat.propModeState("i") === Qt.Checked
                   && harness.chat.propModeState("m") === Qt.Checked
                   && harness.chat.propModeState("n") === Qt.Checked
                   && harness.chat.propModeState("t") === Qt.Unchecked,
                   "i=" + harness.chat.propModeState("i") + " m=" + harness.chat.propModeState("m")
                   + " n=" + harness.chat.propModeState("n") + " t=" + harness.chat.propModeState("t"))
        // A late reply for another channel never repaints this dialog.
        harness.bridge.channel_modes_changed("#other", "mnt")
        harness.ok("wrong-channel modes ignored",
                   harness.chat.propModeState("i") === Qt.Checked
                   && harness.chat.propModeState("m") === Qt.Checked
                   && harness.chat.propModeState("n") === Qt.Checked
                   && harness.chat.propModeState("t") === Qt.Unchecked)
        harness.ok("bridge remembers the flags", harness.bridge.modes_for("#chan") === "im"
                   && harness.bridge.modes_for("#other") === "mnt")

        harness.report()
    }

    function report() {
        console.error(harness.failures === 0 ? "PEOPLE-RESULT: ALL PASS" : ("PEOPLE-RESULT: " + harness.failures + " FAILURES"))
        Qt.exit(harness.failures === 0 ? 0 : 1)
    }
}
