// Perf harness for the incremental message path (see
// .hermes/implementation/p2-perf.md for the numbers this produced).
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
        perf.ok("load_channel loads the snapshot", modelDouble.count === 4, "count=" + modelDouble.count)

        modelDouble.append_message("#other", "x", "wrong buffer", "12:00", false, false)
        perf.ok("append_message no-ops for a non-loaded buffer",
                modelDouble.count === 4 && modelDouble.appendMessageNoops === 1,
                "count=" + modelDouble.count + " noops=" + modelDouble.appendMessageNoops)

        modelDouble.append_message("#PERF", "carol", "case-insensitive insert", "12:07", false, false)
        perf.ok("append_message matches the loaded target case-insensitively",
                modelDouble.count === 5 && modelDouble.appendMessageCalls === 1,
                "count=" + modelDouble.count)

        modelDouble.clear()
        modelDouble.append_message("#perf", "dave", "first row of an empty model", "12:08", false, false)
        perf.ok("append_message inserts into an empty model",
                modelDouble.count === 1 && modelDouble.appendMessageCalls === 2,
                "count=" + modelDouble.count)

        modelDouble.load_channel("#perf")
        modelDouble.append_message("#perf", "erin", "after a reload", "12:09", false, false)
        perf.ok("append_message inserts after a reload, without resetting",
                modelDouble.count === 5 && modelDouble.appendMessageCalls === 3,
                "count=" + modelDouble.count)

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

        console.error(perf.failures === 0 ? "PERF-RESULT: ALL PASS"
                                          : ("PERF-RESULT: " + perf.failures + " FAILURES"))
        Qt.exit(perf.failures === 0 ? 0 : 1)
    }
}
