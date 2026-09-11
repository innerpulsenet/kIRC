import QtQuick

// TEST DOUBLE for the cxx-qt MessageListModel: a real QAbstractListModel with
// the exact contract role names.
//
// The rows deliberately include two consecutive messages from one nick so the
// smoke test can check MessageDelegate's grouping (avatar/name shown once), and
// a highlight + a self line so every role path is exercised.
ListModel {
    id: model

    function load_channel(target) {
        console.error("STUB load_channel(" + target + ")")
        model.clear()
        model.append({"nick": "alice", "text": "hello world https://kde.org and <b>raw html</b>",
                      "timestamp": "12:00", "isSelf": false, "isHighlight": false})
        model.append({"nick": "alice", "text": "second line from alice, one minute later",
                      "timestamp": "12:01", "isSelf": false, "isHighlight": false})
        model.append({"nick": "kircuser", "text": "my own line",
                      "timestamp": "12:02", "isSelf": true, "isHighlight": false})
        model.append({"nick": "bob", "text": "kircuser: please look at this",
                      "timestamp": "12:03", "isSelf": false, "isHighlight": true})
    }
}
