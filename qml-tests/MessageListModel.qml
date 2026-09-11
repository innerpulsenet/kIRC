import QtQuick

// TEST DOUBLE for the cxx-qt MessageListModel: a real QAbstractListModel with
// the exact contract role names.
//
// The rows deliberately include two consecutive messages from one nick so the
// smoke test can check MessageDelegate's grouping (avatar/name shown once), and
// a highlight + a self line so every role path is exercised.
//
// It mirrors the two write paths of the real bridge so a harness can tell them
// apart (and count them):
//   * load_channel(target) — full reload (the real model does
//     beginResetModel/endResetModel): clears and rebuilds the snapshot.
//   * append_message(target, nick, text, timestamp, isSelf, isHighlight) — the
//     incremental fast path for live traffic: ONE row, no reset, and only when
//     `target` is the buffer currently loaded (ASCII case-insensitive).
// The call counters are what tst_perf.qml reports; tst_smoke.qml does not read
// them, it just drives the live path through them.
ListModel {
    id: model

    // Buffer that is currently loaded; append_message only inserts for it.
    property string loadedTarget: ""
    // Emission counters (read by tst_perf.qml to report resets vs inserts).
    property int loadChannelCalls: 0
    property int appendMessageCalls: 0
    property int appendMessageNoops: 0
    // tst_perf.qml sets this > 0 to build a long synthetic transcript for the
    // reload-vs-append comparison; 0 keeps the canned snapshot tst_smoke.qml
    // asserts on.
    property int syntheticRowCount: 0
    // tst_perf.qml turns the per-insert trace off (thousands of lines); the
    // smoke test keeps it on.
    property bool traceAppends: true

    function load_channel(target) {
        console.error("STUB load_channel(" + target + ") rows-before=" + model.count)
        model.loadChannelCalls += 1
        model.loadedTarget = String(target)
        model.clear()
        if (model.syntheticRowCount > 0) {
            for (var i = 0; i < model.syntheticRowCount; ++i) {
                model.append({"nick": "flood" + (i % 7), "text": "buffered transcript line " + i,
                              "timestamp": "09:00", "isSelf": false, "isHighlight": false})
            }
            return
        }
        model.append({"nick": "alice", "text": "hello world https://kde.org and <b>raw html</b>",
                      "timestamp": "12:00", "isSelf": false, "isHighlight": false})
        model.append({"nick": "alice", "text": "second line from alice, one minute later",
                      "timestamp": "12:01", "isSelf": false, "isHighlight": false})
        model.append({"nick": "kircuser", "text": "my own line",
                      "timestamp": "12:02", "isSelf": true, "isHighlight": false})
        model.append({"nick": "bob", "text": "kircuser: please look at this",
                      "timestamp": "12:03", "isSelf": false, "isHighlight": true})
    }

    // Exactly the cxx-qt contract: one row via an insert, no reset, no-op for
    // any buffer that is not the loaded one (or when nothing is loaded).
    function append_message(target, nick, text, timestamp, is_self, is_highlight) {
        if (model.loadedTarget.length === 0
                || String(target).toLowerCase() !== model.loadedTarget.toLowerCase()) {
            model.appendMessageNoops += 1
            console.error("STUB append_message(" + target + ") ignored (loaded="
                          + (model.loadedTarget.length > 0 ? model.loadedTarget : "<none>") + ")")
            return
        }
        var row = model.count
        model.appendMessageCalls += 1
        model.append({"nick": nick, "text": text, "timestamp": timestamp,
                      "isSelf": is_self, "isHighlight": is_highlight})
        if (model.traceAppends) {
            console.error("STUB append_message(" + target + ", " + nick + ") -> inserted row " + row)
        }
    }
}
