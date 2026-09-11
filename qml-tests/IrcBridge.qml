import QtQuick

// TEST DOUBLE for the cxx-qt IrcBridge (same ids, same signature).
QtObject {
    id: bridge

    property int connection_state: 0
    property int unread_count: 0
    property string nickname: ""
    property string connected_server: ""

    signal message_received(string target, string nick, string text, bool is_self, bool is_highlight)
    signal history_batch_received(string target)
    signal state_changed(int state)
    signal notification_fired(string title, string body)
    signal info(string text)
    signal error_occurred(string message)

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
            Qt.callLater(function() {
                bridge.message_received("#kirc", "alice", "hello world https://kde.org and <b>raw html</b>", false, false)
                bridge.message_received("#kirc", nickname, "my own line", true, false)
                bridge.message_received("#kirc", "bob", nickname + ": please look at this", false, true)
                bridge.history_batch_received("#kirc")
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
}
