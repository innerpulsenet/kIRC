import QtQuick

// TEST DOUBLE for the cxx-qt MessageListModel: a real QAbstractListModel with
// the exact contract role names.
//
// Roles (must match rust/src/bridge.rs): nick, text, timestamp, isSelf,
// isHighlight, isEvent, showDay, dayLabel, isError, isPrivate, isNotice,
// isAction.
//
// `isPrivate`/`isNotice`/`isAction` are RAW arrival facts (bridge roles
// 9/10/11): the double carries them through row()/append_message verbatim, so
// MessageDelegate's required properties bind on every path.
//
// `isEvent`/`isError`/`showDay`/`dayLabel` are DERIVED roles: the real model
// computes them once per row when a row is produced (single pass on
// load_channel, O(1) on append_message comparing against the previous row).
// This double mirrors that: every row carries a hidden `dayKey` ("YYYY-MM-DD"),
// isEvent is `nick === "*"`, isError is `isErrorLine(nick, text)` (the same
// classification as Rust: console/service lines only, numerics by range,
// failure phrasing with a success guard), showDay is "this row's day differs
// from the previous row's" and dayLabel is Today / Yesterday / "Sep 11".
//
// The canned snapshot exercises every role path (plain, self, highlight,
// event rows, a failing 473 line, a MOTD line whose text sounds alarming but
// must stay non-error, a NOTICE, a /me action and a query row) plus two day
// boundaries, so the smoke test can assert the contract without a live
// server.
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
    // Distinguishes successive synthetic transcripts so a switch benchmark can
    // force every delegate's role values to change (a real channel switch
    // changes all of them). Empty by default so existing tests see the same
    // row values as before.
    property string syntheticTag: ""
    // tst_perf.qml turns the per-insert trace off (thousands of lines); the
    // smoke test keeps it on.
    property bool traceAppends: true

    // ---- derived-role mirror (real model: rust/src/bridge.rs) -------------

    function dayKeyOf(dayKey) {
        return dayKey === undefined || dayKey === null ? "" : String(dayKey)
    }

    /// Mirror of Rust `line_is_error(nick, text)`: true when a row is a
    /// failure (join rejection, 4xx/5xx numeric, IRC/connection error,
    /// NickServ/ChanServ auth failure). Only synthesized lines are scanned —
    /// console/event rows (nick "*") and service notices; ordinary chatter is
    /// never classified. A leading 3-digit numeric decides by RANGE alone
    /// (372/375/376 MOTD can never be an error), and success notices win over
    /// failure phrasing.
    function isErrorLine(nick, text) {
        var consoleLine = String(nick) === "*"
        var service = !consoleLine
                && (String(nick).toLowerCase() === "nickserv"
                    || String(nick).toLowerCase() === "chanserv")
        if (!consoleLine && !service) {
            return false
        }
        var body = String(text)
        var leading = body.match(/^(\d{3})(\s|$)/)
        if (leading !== null) {
            var code = Number(leading[1])
            return code >= 400 && code <= 599
        }
        var lower = body.toLowerCase()
        if (consoleLine && lower.indexOf("disconnected:") === 0) {
            return true
        }
        var success = ["you are now identified", "you are now logged in",
                       "logged in as", "password accepted", "you have been identified"]
        for (var s = 0; s < success.length; ++s) {
            if (lower.indexOf(success[s]) >= 0) {
                return false
            }
        }
        var failure = ["invalid password", "authentication failed", "identification failed",
                       "not registered", "access denied", "you are not", "denied", "incorrect",
                       "cannot join channel", "is in use, trying"]
        for (var f = 0; f < failure.length; ++f) {
            if (lower.indexOf(failure[f]) >= 0) {
                return true
            }
        }
        return false
    }

    /// Short human label for a "YYYY-MM-DD" key: Today / Yesterday / "Sep 11".
    function dayLabelFor(dayKey) {
        if (model.dayKeyOf(dayKey).length === 0) {
            return ""
        }
        var parts = model.dayKeyOf(dayKey).split("-")
        if (parts.length !== 3) {
            return ""
        }
        var day = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
        var today = new Date()
        today = new Date(today.getFullYear(), today.getMonth(), today.getDate())
        var diffDays = Math.round((today.getTime() - day.getTime()) / 86400000)
        if (diffDays === 0) {
            return "Today"
        }
        if (diffDays === 1) {
            return "Yesterday"
        }
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return months[day.getMonth()] + " " + day.getDate()
    }

    /// Build one row with the derived roles, given the previous row (or null).
    /// `arrival` (optional) carries the raw arrival facts:
    /// {"private": bool, "notice": bool, "action": bool}.
    function row(prev, nick, text, timestamp, isSelf, isHighlight, dayKey, arrival) {
        var key = model.dayKeyOf(dayKey)
        var prevKey = prev === null || prev === undefined ? "" : model.dayKeyOf(prev.dayKey)
        var showDay = key.length > 0 && prevKey.length > 0 && key !== prevKey
        var a = arrival === undefined || arrival === null ? {} : arrival
        return {
            "nick": nick, "text": text, "timestamp": timestamp,
            "isSelf": isSelf, "isHighlight": isHighlight,
            "isEvent": String(nick) === "*",
            "isError": model.isErrorLine(nick, text),
            "isPrivate": a.private === true,
            "isNotice": a.notice === true,
            "isAction": a.action === true,
            "showDay": showDay,
            "dayLabel": key.length > 0 ? model.dayLabelFor(key) : "",
            "dayKey": key
        }
    }

    function todayKey() {
        var d = new Date()
        function pad(n) { return (n < 10 ? "0" : "") + n }
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    }

    function yesterdayKey() {
        var d = new Date()
        d.setDate(d.getDate() - 1)
        function pad(n) { return (n < 10 ? "0" : "") + n }
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    }

    // ---- write paths ------------------------------------------------------

    function load_channel(target) {
        console.error("STUB load_channel(" + target + ") rows-before=" + model.count)
        model.loadChannelCalls += 1
        model.loadedTarget = String(target)
        model.clear()
        if (model.syntheticRowCount > 0) {
            var tag = model.syntheticTag.length > 0 ? ("-" + model.syntheticTag) : ""
            var prev = null
            for (var i = 0; i < model.syntheticRowCount; ++i) {
                var r = model.row(prev, "flood" + (i % 7) + tag, "buffered transcript line " + i,
                                  "09:00", false, false, model.todayKey())
                model.append(r)
                prev = r
            }
            return
        }
        var today = model.todayKey()
        var yesterday = model.yesterdayKey()
        var raw = [
            ["alice", "hello world https://kde.org and <b>raw html</b>", "12:00", false, false, today],
            ["alice", "second line from alice, one minute later", "12:01", false, false, today],
            ["kircuser", "my own line", "12:02", true, false, today],
            ["bob", "kircuser: please look at this", "12:03", false, true, today],
            ["*", "bob left #kirc", "23:58", false, false, yesterday],
            ["dave", "morning from the other side", "00:01", false, false, today],
            ["*", "erin joined #kirc", "00:02", false, false, today],
            // A failing console line (the user's "473 ... Cannot join
            // channel (+i)") and a MOTD line whose text *sounds* like a
            // failure — the numeric range must keep the MOTD non-error.
            ["*", "473 #pain Cannot join channel (+i)", "12:04", false, false, today],
            ["*", "372 - MOTD: incorrect settings are denied", "12:05", false, false, today],
            // Per-kind coverage (theme schema 4): a NOTICE in a conversation,
            // a CTCP ACTION and a query row, each flagged with its raw
            // arrival fact so the delegate's role branches are all exercised.
            ["alice", "psst - are you around?", "12:06", false, false, today,
             {"notice": true}],
            ["carol", "* does a little dance", "12:07", false, false, today,
             {"action": true}],
            ["dave", "this line came from a query buffer", "12:08", false, false, today,
             {"private": true}]
        ]
        var prev = null
        for (var j = 0; j < raw.length; ++j) {
            var r = model.row(prev, raw[j][0], raw[j][1], raw[j][2], raw[j][3], raw[j][4],
                              raw[j][5], raw[j][6])
            model.append(r)
            prev = r
        }
    }

    function prepend_history(target) {
        // The QML double has no persistent backing store; record the fast-path
        // call without resetting its live rows.
        if (String(target).toLowerCase() !== model.loadedTarget.toLowerCase()) {
            return
        }
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
        var rowIndex = model.count
        var prev = model.count > 0 ? model.get(model.count - 1) : null
        model.appendMessageCalls += 1
        model.append(model.row(prev, nick, text, timestamp, is_self, is_highlight,
                               prev === null ? model.todayKey() : model.dayKeyOf(prev.dayKey)))
        if (model.traceAppends) {
            console.error("STUB append_message(" + target + ", " + nick + ") -> inserted row " + rowIndex)
        }
    }
}
