import QtQuick

// TEST DOUBLE for the cxx-qt IrcBridge (same ids, same signature).
//
// The model roles (including the derived isError flag) belong to the
// MessageListModel double; this bridge double only has to produce the same
// signals the cxx-qt bridge does. A failed join mirrors the real bridge's
// behaviour: the failure reason (a "473 ..." numeric line) is written to the
// *server* console buffer via message_received BEFORE join_failed fires, so
// the model's isError derivation sees the same row it would in the app.
QtObject {
    id: bridge

    property int connection_state: 0
    property int unread_count: 0
    property int sasl_mechanism: 0
    // Mirrors IrcBridge::set_ctcp_version_reply; kept so a test can assert
    // the applied value, not just the call.
    property bool ctcp_version_reply: true
    property string nickname: ""
    property string connected_server: ""
    property var unreadByTarget: ({})

    // ---- call recording (asserted by tst_cmds.qml) ------------------------
    // Every invokable appends { "fn": name, "args": [...] } here so a test can
    // assert the exact call a slash command produced (the wire line, the
    // bridge call) instead of grepping stderr.  Purely additive: the STUB
    // traces and every signal stay exactly as they were.
    property var calls: []

    function record(name, args) {
        bridge.calls = bridge.calls.concat([{ "fn": name, "args": args }])
    }
    function clearCalls() {
        bridge.calls = []
    }
    /// "fn(arg1, arg2) fn2(arg)" for the calls made since the last clear.
    function callTrace() {
        var out = []
        for (var i = 0; i < bridge.calls.length; ++i) {
            out.push(bridge.calls[i].fn + "(" + bridge.calls[i].args.join(", ") + ")")
        }
        return out.join(" ")
    }

    // timestamp is the preformatted "HH:MM" string ("" when unknown); the
    // cxx-qt bridge passes the very string its STORE row carries.
    signal message_received(string target, string nick, string text, string timestamp, bool is_self, bool is_highlight)
    signal history_batch_received(string target)
    signal state_changed(int state)
    signal notification_fired(string title, string body)
    signal info(string text)
    signal error_occurred(string message)
    signal channel_joined(string channel)
    signal channel_parted(string channel)
    signal join_failed(string channel, string reason)
    signal topic_changed(string channel, string topic)
    signal names_updated(string channel, string nicks)
    signal query_opened(string nick)

    function mark_read() {
        bridge.record("mark_read", [])
        console.error("STUB mark_read()")
        bridge.unread_count = 0
    }
    function mark_buffer_read(target) {
        // Keep legacy command traces stable; dedicated assertions inspect the
        // per-target map rather than treating read bookkeeping as a command.
        bridge.record("mark_read", [])
        var key = String(target).toLowerCase()
        var count = bridge.unreadByTarget[key] || 0
        var next = Object.assign({}, bridge.unreadByTarget)
        delete next[key]
        bridge.unreadByTarget = next
        bridge.unread_count = Math.max(0, bridge.unread_count - count)
    }
    function unread_for(target) {
        return bridge.unreadByTarget[String(target).toLowerCase()] || 0
    }
    function set_sasl_mechanism(mechanism) {
        bridge.record("set_sasl_mechanism", [mechanism])
        console.error("STUB set_sasl_mechanism(" + mechanism + ")")
        bridge.sasl_mechanism = mechanism
    }
    // Mirrors IrcBridge::set_ctcp_version_reply (whether an incoming CTCP
    // VERSION query is answered).  Not a secret: the value stays in the call
    // trace.
    function set_ctcp_version_reply(enabled) {
        bridge.record("set_ctcp_version_reply", [enabled])
        console.error("STUB set_ctcp_version_reply(" + enabled + ")")
        bridge.ctcp_version_reply = enabled
    }
    // Mirrors IrcBridge::set_server_password (PASS for the next connection).
    // The secret itself is never recorded or echoed, not even by a test
    // double, so the call trace stays safe to print.
    function set_server_password(password) {
        bridge.record("set_server_password", ["<redacted>"])
        console.error("STUB set_server_password(<redacted>)")
    }
    function connect_server(host, port, tls, nickname, sasl_user, sasl_pass) {
        bridge.record("connect_server", [host, port, tls, nickname, sasl_user])
        console.error("STUB connect_server(" + host + ", " + port + ", " + tls + ", " + nickname + ", " + sasl_user + ")")
        bridge.nickname = nickname
        bridge.connected_server = host
        bridge.connection_state = 1
        bridge.state_changed(1)
        Qt.callLater(function() {
            bridge.connection_state = 2
            bridge.connected_server = host + ":" + port + (tls ? " (TLS)" : "")
            bridge.state_changed(2)
            bridge.channel_joined("#kirc")
            Qt.callLater(function() {
                bridge.message_received("#kirc", "alice", "hello world https://kde.org and <b>raw html</b>", "12:04", false, false)
                bridge.message_received("#kirc", nickname, "my own line", "12:05", true, false)
                bridge.message_received("#kirc", "bob", nickname + ": please look at this", "12:06", false, true)
                bridge.history_batch_received("#kirc")
                bridge.names_updated("#kirc", "alice @" + nickname + " bob")
                bridge.topic_changed("#kirc", "kIRC development")
            })
        })
    }
    function disconnect_server() {
        bridge.record("disconnect_server", [])
        bridge.connection_state = 0
        bridge.state_changed(0)
    }
    function send_message(target, text) {
        bridge.record("send_message", [target, text])
        console.error("STUB send_message(" + target + ", " + text + ")")
    }
    function request_history(target, limit) {
        bridge.record("request_history", [target, limit])
        console.error("STUB request_history(" + target + ", " + limit + ")")
    }
    function join_channel(channel) {
        bridge.record("join_channel", [channel])
        console.error("STUB join_channel(" + channel + ")")
        if (channel.indexOf("pain") !== -1) {
            var reason = "473 " + channel + " Cannot join channel (+i)"
            // Same order as the real bridge (handle_event): console line, then
            // the join_failed signal.
            bridge.message_received("*server*", "*", reason, "12:07", false, false)
            bridge.join_failed(channel, reason)
            return
        }
        Qt.callLater(function() { bridge.channel_joined(channel) })
    }
    function part_channel(channel) {
        bridge.record("part_channel", [channel])
        console.error("STUB part_channel(" + channel + ")")
        bridge.channel_parted(channel)
    }
    function nicks_for(channel) {
        return channel.charAt(0) === "#" ? "alice bob" : ""
    }
    function topic_for(channel) {
        return channel.charAt(0) === "#" ? "kIRC development" : ""
    }
    function send_raw(line) {
        bridge.record("send_raw", [line])
        console.error("STUB send_raw(" + line + ")")
    }
    function clear_buffer(target) {
        bridge.record("clear_buffer", [target])
        console.error("STUB clear_buffer(" + target + ")")
    }
}
