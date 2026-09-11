#!/bin/sh
# Perf harness runner for the incremental message path AND the channel-switch
# (delegate) path.
#
# Builds a throwaway org.kde.kirc module out of the real qml/ files plus the
# doubles in this directory and runs tst_perf.qml headless.  Reports
# reload-vs-append emission counts, the channel-switch timings and the
# itemAtIndex scan count, exit code 0 = all checks passed.
#
# The delegate copy is instrumented with a counter when (and only when) it
# still contains itemAtIndex call sites — that is what produces the "before"
# scan count on the pre-fix revision, and 0 on the current one. The grep below
# always prints the static call-site count so the report shows the real number.
#
# Usage:  qml-tests/perf.sh
# Env:    QML_BIN (default /usr/lib64/qt6/bin/qml)
#         QPA     (default offscreen; use "xcb" to watch it run)

set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
qmlbin=${QML_BIN:-/usr/lib64/qt6/bin/qml}
qpa=${QPA:-offscreen}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/org/kde/kirc"
cp "$root"/rust/qml/*.qml "$root"/rust/qml/Theme.js "$tmp/org/kde/kirc/"
cp -r "$root"/rust/qml/themes "$tmp/org/kde/kirc/"
cp "$here"/IrcBridge.qml "$here"/MessageListModel.qml "$here"/BenchCount.qml "$tmp/org/kde/kirc/"

# qmldir mirroring the one cxx-qt generates for the real module.
printf 'module org.kde.kirc\nsingleton BenchCount 1.0 BenchCount.qml\nsingleton ThemeEngine 1.0 ThemeEngine.qml\nIrcBridge 1.0 IrcBridge.qml\nMessageListModel 1.0 MessageListModel.qml\nChatPage 1.0 ChatPage.qml\nConnectPage 1.0 ConnectPage.qml\nMessageDelegate 1.0 MessageDelegate.qml\n' \
    > "$tmp/org/kde/kirc/qmldir"

# Static evidence: how many itemAtIndex call sites the delegate has.
sites=$(grep -c 'itemAtIndex' "$root/rust/qml/MessageDelegate.qml" || true)
echo "PERF-HARNESS MessageDelegate.qml itemAtIndex call sites: $sites"

# Instrument the delegate copy so a scan (if any) is counted dynamically.
if [ "$sites" != "0" ]; then
    python3 - "$tmp/org/kde/kirc/MessageDelegate.qml" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
before = src
# viewIndex(): one call per scanned row.
src = src.replace(
    '            if (view.itemAtIndex(i) === delegate) {',
    '            BenchCount.itemAtIndexCalls += 1\n'
    '            if (view.itemAtIndex(i) === delegate) {', 1)
# neighbourAt(): one call per neighbour lookup.
src = src.replace(
    '        return view.itemAtIndex(index)',
    '        BenchCount.itemAtIndexCalls += 1\n'
    '        return view.itemAtIndex(index)', 1)
open(path, 'w').write(src)
print("PERF-HARNESS instrumented the delegate copy (scans will be counted)"
      if src != before else "PERF-HARNESS WARNING: itemAtIndex sites not found verbatim; not instrumented")
PY
else
    echo "PERF-HARNESS delegate has no itemAtIndex call sites; nothing to instrument"
fi

cp "$here"/tst_perf.qml "$tmp/"

# QT_FORCE_STDERR_LOGGING: without it Qt logs to the journal, not the terminal.
exec env QML2_IMPORT_PATH="$tmp" \
         QT_FORCE_STDERR_LOGGING=1 \
         QT_QPA_PLATFORM="$qpa" \
         "$qmlbin" "$tmp/tst_perf.qml"
