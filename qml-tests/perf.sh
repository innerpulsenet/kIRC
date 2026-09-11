#!/bin/sh
# Perf harness runner for the incremental message path.
#
# Builds a throwaway org.kde.kirc module out of the test double in this
# directory and runs tst_perf.qml headless.  Reports reload-vs-append emission
# counts and timings, exit code 0 = all checks passed.
#
# Usage:  qml-tests/perf.sh
# Env:    QML_BIN (default /usr/lib64/qt6/bin/qml)
#         QPA     (default offscreen; use "xcb" to watch it run)

set -e

here=$(cd "$(dirname "$0")" && pwd)
qmlbin=${QML_BIN:-/usr/lib64/qt6/bin/qml}
qpa=${QPA:-offscreen}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/org/kde/kirc"
cp "$here"/MessageListModel.qml "$tmp/org/kde/kirc/"
printf 'module org.kde.kirc\nMessageListModel 1.0 MessageListModel.qml\n' \
    > "$tmp/org/kde/kirc/qmldir"

cp "$here"/tst_perf.qml "$tmp/"

# QT_FORCE_STDERR_LOGGING: without it Qt logs to the journal, not the terminal.
exec env QML2_IMPORT_PATH="$tmp" \
         QT_FORCE_STDERR_LOGGING=1 \
         QT_QPA_PLATFORM="$qpa" \
         "$qmlbin" "$tmp/tst_perf.qml"
