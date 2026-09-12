// Perf harness for the incremental message path AND the channel-switch
// (delegate) path (see .hermes/implementation/p2-perf.md and p3-render.md).
//
// Loads the MessageListModel test double (which mirrors the cxx-qt model's
// contract) and measures, on a synthetic long transcript:
//
//   * the RELOAD path — one load_channel() per message, which is what the live
//                       path used to do: the whole buffer is rebuilt and the
//                       real model emits begin/endResetModel;
//   * the APPEND path — one append_message() per message: exactly one
//                       rowsInserted, never a reset.
//
// It then exercises the RENDER side — the pause the user actually feels when
// clicking a channel. A real ListView hosts the real MessageDelegate over a
// second model double, every row of the new transcript is instantiated, and
// the harness reports:
//
//   * the wall-clock cost of a full switch (load_channel + delegate creation),
//   * the number of ListView.itemAtIndex() calls the delegates made — the
//     O(n^2) grouping scan of the pre-fix revision called it ~4x per delegate
//     per row; it must be 0 now,
//   * that no delegate carries the old grouping/scan machinery (it used to
//     expose continuesPrevious/continuesNext/settle/viewIndex),
//   * that the model-computed roles (isEvent/isError/showDay/dayLabel) reach
//     the delegate and gate what it renders — including a failing "473 ..."
//     row (warn colour + "!" marker) next to a MOTD row that stays dim.
//
// The counters are wired to the model's real Qt signals (rowsInserted /
// rowsRemoved / modelReset) via a Connections element, so the emission counts
// reported below are the signals a hosting view actually receives.
import QtQuick
import org.kde.kirc 1.0

Item {
    id: perf
    width: 1024
    height: 700

    // Sized so the harness stays quick; the printed PERF lines quote the
    // values actually used.
    property int bufferRows: 2000
    property int reloads: 60
    property int appends: 6000

    // The canned snapshot of the double (tst_smoke.qml asserts on it too).
    // 12 rows since theme schema 4 added the NOTICE / /me / query rows.
    property int snapshotRows: 12

    // Channel-switch benchmark: rows per transcript, timed repetitions.
    property int switchRows: 500
    property int switchReps: 2

    property int failures: 0
    property int resetEmits: 0      // modelReset emissions
    property int insertRanges: 0    // rowsInserted emissions
    property int insertedRows: 0
    property int removedRanges: 0
    property int removedRows: 0

    MessageListModel { id: modelDouble }

    Connections {
        target: modelDouble
        function onModelReset() { perf.resetEmits += 1 }
        function onRowsInserted(parent, first, last) {
            perf.insertRanges += 1
            perf.insertedRows += (last - first + 1)
        }
        function onRowsRemoved(parent, first, last) {
            perf.removedRanges += 1
            perf.removedRows += (last - first + 1)
        }
    }

    // A stuck harness must fail loudly instead of hanging the runner.
    Timer {
        id: watchdog
        interval: 90000
        running: true
        repeat: false
        onTriggered: {
            console.error("PERF watchdog: harness stuck (rep=" + perf.switchRep
                          + " modelCount=" + switchModel.count + " viewCount=" + switchView.count + ")")
            console.error("PERF-RESULT: STUCK")
            Qt.exit(2)
        }
    }

    // ------------------------------------------------------------------ //
    // Render side: a real ListView over a second model instance. The view is
    // tall enough that every row is inside the viewport, so a "switch"
    // instantiates the full delegate set exactly like the app's channel click.
    // reuseItems mirrors ChatPage's messageView.
    // ------------------------------------------------------------------ //
    MessageListModel { id: switchModel }

    ListView {
        id: switchView
        width: perf.width
        height: perf.switchRows * 40 + 400
        model: switchModel
        delegate: MessageDelegate { }
        reuseItems: true
        cacheBuffer: 2000
        spacing: 0
    }

    function ok(name, cond, extra) {
        if (cond) {
            console.error("PASS " + name + (extra !== undefined ? " :: " + extra : ""))
        } else {
            perf.failures++
            console.error("FAIL " + name + (extra !== undefined ? " :: " + extra : ""))
        }
    }

    Component.onCompleted: Qt.callLater(perf.run)

    function run() {
        // ---- contract checks on the canned snapshot ---------------------
        modelDouble.traceAppends = false
        modelDouble.syntheticRowCount = 0
        modelDouble.load_channel("#perf")
        perf.ok("load_channel loads the snapshot", modelDouble.count === perf.snapshotRows,
                "count=" + modelDouble.count)

        modelDouble.append_message("#other", "x", "wrong buffer", "12:00", false, false)
        perf.ok("append_message no-ops for a non-loaded buffer",
                modelDouble.count === perf.snapshotRows && modelDouble.appendMessageNoops === 1,
                "count=" + modelDouble.count + " noops=" + modelDouble.appendMessageNoops)

        modelDouble.append_message("#PERF", "carol", "case-insensitive insert", "12:07", false, false)
        perf.ok("append_message matches the loaded target case-insensitively",
                modelDouble.count === perf.snapshotRows + 1 && modelDouble.appendMessageCalls === 1,
                "count=" + modelDouble.count)

        modelDouble.clear()
        modelDouble.append_message("#perf", "dave", "first row of an empty model", "12:08", false, false)
        perf.ok("append_message inserts into an empty model",
                modelDouble.count === 1 && modelDouble.appendMessageCalls === 2,
                "count=" + modelDouble.count)

        modelDouble.load_channel("#perf")
        modelDouble.append_message("#perf", "erin", "after a reload", "12:09", false, false)
        perf.ok("append_message inserts after a reload, without resetting",
                modelDouble.count === perf.snapshotRows + 1 && modelDouble.appendMessageCalls === 3,
                "count=" + modelDouble.count)

        // The live path derives isError from the row's content, exactly like
        // the batch pass: a NickServ failure lands flagged, ordinary chatter
        // (even numeric-sounding chatter) never does.
        modelDouble.append_message("#perf", "NickServ", "Invalid password.", "12:10", false, false)
        var liveFailure = modelDouble.get(modelDouble.count - 1)
        perf.ok("append path flags a NickServ auth failure",
                liveFailure.isError === true && liveFailure.nick === "NickServ",
                "isError=" + liveFailure.isError + " nick=" + liveFailure.nick)
        modelDouble.append_message("#perf", "alice", "404 skill not found, you are not funny", "12:11", false, false)
        var liveChatter = modelDouble.get(modelDouble.count - 1)
        perf.ok("append path leaves ordinary chatter alone",
                liveChatter.isError === false && liveChatter.isEvent === false,
                "isError=" + liveChatter.isError)

        // ---- model-computed derived roles (mirror of the Rust model) ----
        var row4 = modelDouble.get(4)
        perf.ok("snapshot row 4 is an event row on a new day",
                row4.isEvent === true && row4.showDay === true && row4.dayLabel === "Yesterday",
                "isEvent=" + row4.isEvent + " showDay=" + row4.showDay + " label=" + row4.dayLabel)
        var row5 = modelDouble.get(5)
        perf.ok("snapshot row 5 starts a new day with the Today label",
                row5.isEvent === false && row5.showDay === true && row5.dayLabel === "Today",
                "showDay=" + row5.showDay + " label=" + row5.dayLabel)
        var row0 = modelDouble.get(0)
        perf.ok("snapshot row 0 has no predecessor, so no day rule",
                row0.showDay === false && row0.isEvent === false && row0.isError === false,
                "showDay=" + row0.showDay + " isError=" + row0.isError)

        // ---- isError: failing lines only ---------------------------------
        var errRow = modelDouble.get(7)
        perf.ok("snapshot row 7 is the failing 473 line",
                errRow.isEvent === true && errRow.isError === true && errRow.showDay === false
                && errRow.text === "473 #pain Cannot join channel (+i)",
                "isError=" + errRow.isError + " text=" + errRow.text)
        var motdRow = modelDouble.get(8)
        perf.ok("snapshot row 8 is a MOTD line and never an error",
                motdRow.isEvent === true && motdRow.isError === false,
                "isError=" + motdRow.isError + " text=" + motdRow.text)

        // ---- long transcript: reload path vs append path -----------------
        modelDouble.syntheticRowCount = perf.bufferRows
        var started = Date.now()
        modelDouble.load_channel("#perf")
        console.error("PERF initial load of " + perf.bufferRows + " rows: " + (Date.now() - started) + " ms")
        perf.ok("long transcript loaded", modelDouble.count === perf.bufferRows, "count=" + modelDouble.count)

        // RELOAD path (what every live message used to trigger).
        var relLoads0 = modelDouble.loadChannelCalls
        var relAppends0 = modelDouble.appendMessageCalls
        var relResets0 = perf.resetEmits
        var relInsR0 = perf.insertRanges
        var relRemR0 = perf.removedRanges
        started = Date.now()
        for (var r = 0; r < perf.reloads; ++r) {
            modelDouble.load_channel("#perf") // == one begin/endResetModel in the real model
        }
        var reloadMs = Date.now() - started
        console.error("PERF reload path: " + perf.reloads + " messages on a " + perf.bufferRows + "-row buffer -> "
                      + "reloadCalls=" + (modelDouble.loadChannelCalls - relLoads0)
                      + " appendCalls=" + (modelDouble.appendMessageCalls - relAppends0)
                      + " rowsRemovedRanges=" + (perf.removedRanges - relRemR0)
                      + " rowsInsertedRanges=" + (perf.insertRanges - relInsR0)
                      + " modelReset=" + (perf.resetEmits - relResets0)
                      + " totalMs=" + reloadMs
                      + " perMessageUs=" + Math.round(reloadMs * 1000 / perf.reloads))

        // APPEND path (the new live path).
        var appLoads0 = modelDouble.loadChannelCalls
        var appAppends0 = modelDouble.appendMessageCalls
        var appResets0 = perf.resetEmits
        var appInsR0 = perf.insertRanges
        var appInsRows0 = perf.insertedRows
        var appRemR0 = perf.removedRanges
        started = Date.now()
        for (var a = 0; a < perf.appends; ++a) {
            modelDouble.append_message("#perf", "livetalker", "live line " + a, "12:30", false, false)
        }
        var appendMs = Date.now() - started
        console.error("PERF append path: " + perf.appends + " messages on a " + perf.bufferRows + "-row buffer -> "
                      + "reloadCalls=" + (modelDouble.loadChannelCalls - appLoads0)
                      + " appendCalls=" + (modelDouble.appendMessageCalls - appAppends0)
                      + " rowsInsertedRanges=" + (perf.insertRanges - appInsR0)
                      + " rowsInsertedRows=" + (perf.insertedRows - appInsRows0)
                      + " rowsRemovedRanges=" + (perf.removedRanges - appRemR0)
                      + " modelReset=" + (perf.resetEmits - appResets0)
                      + " totalMs=" + appendMs
                      + " perMessageUs=" + Math.round(appendMs * 1000 / perf.appends))

        perf.ok("append path inserts exactly one row per message",
                (perf.insertRanges - appInsR0) === perf.appends
                && (perf.insertedRows - appInsRows0) === perf.appends,
                "ranges=" + (perf.insertRanges - appInsR0))
        perf.ok("append path performs no reloads and no resets",
                (modelDouble.loadChannelCalls - appLoads0) === 0 && (perf.resetEmits - appResets0) === 0)
        perf.ok("model grew by exactly the appended rows",
                modelDouble.count === perf.bufferRows + perf.appends, "count=" + modelDouble.count)

        // ---- channel switch: load_channel + full delegate creation -------
        perf.startSwitchBenchmark()
    }

    // -------------------------------------------------------------------- //
    // Switch benchmark state
    // -------------------------------------------------------------------- //
    property int switchRep: 0
    property double switchT0: 0
    property int switchCalls0: 0
    property var switchTimes: []

    function startSwitchBenchmark() {
        switchModel.traceAppends = false
        switchModel.syntheticRowCount = perf.switchRows
        perf.switchRep = 0
        perf.switchTimes = []
        // Count the delegate-side view scans from here on (perf.sh instruments
        // the delegate copy; on the current delegate there is nothing to count).
        BenchCount.itemAtIndexCalls = 0
        perf.nextSwitchRep()
    }

    function expectedNick() {
        var tag = switchModel.syntheticTag.length > 0 ? ("-" + switchModel.syntheticTag) : ""
        return "flood" + ((switchModel.count - 1) % 7) + tag
    }

    // The synthetic tag changes every rep, so a stale delegate from the
    // previous transcript can never satisfy this: the row counts as created
    // only once the view has re-bound it.
    function switchRowsReady() {
        if (switchModel.count === 0) {
            return false
        }
        var last = switchView.itemAtIndex(switchModel.count - 1)
        return switchView.count === switchModel.count && last !== null
            && last.text === ("buffered transcript line " + (switchModel.count - 1))
            && last.nick === perf.expectedNick()
    }

    Timer {
        id: switchPoll
        interval: 1
        repeat: false
        onTriggered: perf.switchCheck()
    }

    function nextSwitchRep() {
        perf.switchRep += 1
        switchModel.syntheticTag = "r" + perf.switchRep
        perf.switchCalls0 = BenchCount.itemAtIndexCalls
        perf.switchT0 = Date.now()
        switchModel.load_channel("#switch-" + perf.switchRep)
        perf.switchCheck()
    }

    function switchCheck() {
        if (perf.switchRowsReady()) {
            // one more event-loop pass so any deferred (Qt.callLater) work has
            // run before the clock stops
            Qt.callLater(perf.switchFinish)
        } else {
            switchPoll.restart()
        }
    }

    function switchFinish() {
        var ms = Date.now() - perf.switchT0
        var calls = BenchCount.itemAtIndexCalls - perf.switchCalls0
        perf.switchTimes.push(ms)
        console.error("PERF switch #" + perf.switchRep + " (" + perf.switchRows
                      + " rows, load_channel + full delegate creation): " + ms
                      + " ms, itemAtIndex calls=" + calls
                      + ", delegates=" + switchView.count)
        if (perf.switchRep < perf.switchReps) {
            Qt.callLater(perf.nextSwitchRep)
        } else {
            var sum = 0
            var max = 0
            for (var i = 0; i < perf.switchTimes.length; ++i) {
                sum += perf.switchTimes[i]
                if (perf.switchTimes[i] > max) { max = perf.switchTimes[i] }
            }
            console.error("PERF switch summary: reps=" + perf.switchReps
                          + " avgMs=" + Math.round(sum / perf.switchTimes.length) + " maxMs=" + max
                          + " totalItemAtIndexCalls=" + BenchCount.itemAtIndexCalls)

            perf.ok("every delegate of the new transcript was created",
                    switchView.count === perf.switchRows, "delegates=" + switchView.count)
            perf.ok("delegates never scan the view for their row (itemAtIndex calls)",
                    BenchCount.itemAtIndexCalls === 0,
                    "itemAtIndex calls=" + BenchCount.itemAtIndexCalls)
            perf.delegateChecks()
        }
    }

    // -------------------------------------------------------------------- //
    // Delegate contract: roles reach the delegate, old machinery is gone.
    // -------------------------------------------------------------------- //
    function cannedRowsReady() {
        if (switchModel.count !== perf.snapshotRows) {
            return false
        }
        var last = switchView.itemAtIndex(switchModel.count - 1)
        // The last row of the (schema-4) snapshot is the query row; before the
        // per-kind additions it was the "372 - MOTD ..." line (which is still
        // index 8 and still asserted below).
        return last !== null && last.text === "this line came from a query buffer"
            && last.isPrivate === true && last.isEvent === false
    }

    Timer {
        id: cannedPoll
        interval: 1
        repeat: false
        onTriggered: {
            if (perf.cannedRowsReady()) {
                Qt.callLater(perf.runDelegateChecks)
            } else {
                cannedPoll.restart()
            }
        }
    }

    function delegateChecks() {
        switchModel.syntheticRowCount = 0
        switchModel.syntheticTag = ""
        switchModel.load_channel("#canned")
        cannedPoll.restart()
    }

    /// All `text` values of an item's descendant Texts, joined.
    function collectTexts(item, out, depth) {
        if (item === null || item === undefined || depth > 8) {
            return out
        }
        if (typeof item.text === "string") {
            out.push(item.text)
        }
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) {
            perf.collectTexts(kids[i], out, depth + 1)
        }
        return out
    }

    function renderedText(index) {
        var item = switchView.itemAtIndex(index)
        if (item === null) {
            return ""
        }
        return perf.collectTexts(item, [], 0).join(" | ")
    }

    function runDelegateChecks() {
        var checked = 0
        var machinery = 0
        for (var i = 0; i < switchView.count; ++i) {
            var it = switchView.itemAtIndex(i)
            if (it === null) {
                continue
            }
            checked += 1
            if (typeof it.viewIndex !== "undefined" || typeof it.settle !== "undefined"
                    || it.continuesPrevious !== undefined || it.continuesNext !== undefined
                    || it.showDaySeparator !== undefined || it.latestDay !== undefined
                    || it.neighbourAt !== undefined) {
                machinery += 1
            }
        }
        perf.ok("no delegate exposes the grouping/settle/viewIndex machinery",
                checked === perf.snapshotRows && machinery === 0,
                "delegates=" + checked + " with machinery=" + machinery)

        var row0 = switchView.itemAtIndex(0)
        perf.ok("plain row renders from the roles",
                row0 !== null && row0.nick === "alice" && row0.isEvent === false
                && row0.isError === false && row0.showDay === false && row0.dayLabel === "Today",
                row0 ? ("nick=" + row0.nick + " showDay=" + row0.showDay + " label=" + row0.dayLabel
                        + " isError=" + row0.isError) : "null")
        perf.ok("plain row carries no day rule (showDay gates it)",
                perf.renderedText(0).indexOf("Today") === -1, perf.renderedText(0))

        var row4 = switchView.itemAtIndex(4)
        perf.ok("event row renders dim, with the * marker and its day rule",
                row4 !== null && row4.isEvent === true && row4.showDay === true
                && row4.dayLabel === "Yesterday"
                && perf.renderedText(4).indexOf("Yesterday") >= 0
                && perf.renderedText(4).indexOf("* bob left #kirc") >= 0,
                row4 ? ("isEvent=" + row4.isEvent + " showDay=" + row4.showDay
                        + " rendered=" + perf.renderedText(4)) : "null")

        var row5 = switchView.itemAtIndex(5)
        perf.ok("day rule renders the model's label on the first row of the day",
                row5 !== null && row5.showDay === true && row5.dayLabel === "Today"
                && perf.renderedText(5).indexOf("Today") >= 0,
                row5 ? ("showDay=" + row5.showDay + " rendered=" + perf.renderedText(5)) : "null")

        var row7 = switchView.itemAtIndex(7)
        perf.ok("failing row renders the ! marker in the warn colour",
                row7 !== null && row7.isError === true
                && perf.renderedText(7).indexOf("! 473 #pain Cannot join channel (+i)") >= 0
                && row7.bodyColor.toString() === row7.fgWarnColor.toString()
                && row7.fgWarnColor.toString() !== row7.fgDimColor.toString(),
                row7 ? ("isError=" + row7.isError + " body=" + row7.bodyColor
                        + " warn=" + row7.fgWarnColor + " rendered=" + perf.renderedText(7)) : "null")

        var row8 = switchView.itemAtIndex(8)
        perf.ok("MOTD row stays dim, no ! marker and no warn colour",
                row8 !== null && row8.isError === false
                && perf.renderedText(8).indexOf("* 372 - MOTD") >= 0
                && perf.renderedText(8).indexOf("! 372") === -1
                && row8.bodyColor.toString() === row8.fgDimColor.toString(),
                row8 ? ("isError=" + row8.isError + " body=" + row8.bodyColor
                        + " rendered=" + perf.renderedText(8)) : "null")

        console.error(perf.failures === 0 ? "PERF-RESULT: ALL PASS"
                                          : ("PERF-RESULT: " + perf.failures + " FAILURES"))
        Qt.exit(perf.failures === 0 ? 0 : 1)
    }
}
