pragma Singleton
import QtQuick

// TEST HARNESS singleton (dev-only, never shipped).
//
// Counts `ListView.itemAtIndex()` calls made from MessageDelegate, so
// tst_perf.qml can prove the O(n^2) view-scanning machinery is gone. perf.sh
// instruments the delegate *copy* inside its throwaway module (if the file
// still contains itemAtIndex call sites) to bump this counter; the current
// delegate has none, so the counter stays 0 — any regression that reintroduces
// a scan makes the perf harness report non-zero and fail.
QtObject {
    property int itemAtIndexCalls: 0
}
