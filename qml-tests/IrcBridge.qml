import QtQuick

// TEST DOUBLE for the cxx-qt IrcBridge (same ids, same signature).
QtObject {
    id: bridge

    property int connection_state: 0
    property int unread_count: 0
    property int sasl_mechanism: 0
    property string nickname: ""
    property string connected_server: ""

    signal message_received(string target, string nick, string text, bool is_self, bool is_highlight)
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
        console.error("STUB mark_read()")
        bridge.unread_count = 0
    }
    function set_sasl_mechanism(mechanism) {
        console.error("STUB set_sasl_mechanism(" + mechanism + ")")
        bridge.sasl_mechanism = mechanism
    }
    function connect_server(host, port, tls, nickname, sasl_user, sasl_pass) {
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
                bridge.message_received("#kirc", "alice", "hello world https://kde.org and <b>raw html</b>", false, false)
                bridge.message_received("#kirc", nickname, "my own line", true, false)
                bridge.message_received("#kirc", "bob", nickname + ": please look at this", false, true)
                bridge.history_batch_received("#kirc")
                bridge.names_updated("#kirc", "alice @" + nickname + " bob")
                bridge.topic_changed("#kirc", "kIRC development")
            })
        })
    }
    function disconnect_server() {
        bridge.connection_state = 0
        bridge.state_changed(0)
    }
    function send_message(target, text) {
        console.error("STUB send_message(" + target + ", " + text + ")")
    }
    function request_history(target, limit) {
        console.error("STUB request_history(" + target + ", " + limit + ")")
    }
    function join_channel(channel) {
        console.error("STUB join_channel(" + channel + ")")
        if (channel.indexOf("pain") !== -1) {
            bridge.join_failed(channel, "473 " + channel + " Cannot join channel (+i)")
            return
        }
        Qt.callLater(function() { bridge.channel_joined(channel) })
    }
    function part_channel(channel) {
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
        console.error("STUB send_raw(" + line + ")")
    }
    function clear_buffer(target) {
        console.error("STUB clear_buffer(" + target + ")")
    }
}
