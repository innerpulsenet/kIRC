#!/bin/sh
# Runtime smoke test for the kIRC QML UI.
#
# Builds a temporary org.kde.kirc module out of the real qml/ files plus the
# cxx-qt test doubles in this directory, then runs tst_smoke.qml headless.
#
# Usage:  qml-tests/run.sh
# Env:    QML_BIN (default /usr/lib64/qt6/bin/qml)
#         QPA     (default offscreen; use "xcb" to watch the UI run)
#
# Exit code: 0 = every check passed.

set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
qmlbin=${QML_BIN:-/usr/lib64/qt6/bin/qml}
qpa=${QPA:-offscreen}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/org/kde/kirc"
cp "$root"/qml/*.qml "$root"/qml/Theme.js "$tmp/org/kde/kirc/"
cp -r "$root"/qml/themes "$tmp/org/kde/kirc/"
cp "$here"/IrcBridge.qml "$here"/MessageListModel.qml "$tmp/org/kde/kirc/"

printf 'module org.kde.kirc\nsingleton ThemeEngine 1.0 ThemeEngine.qml\nIrcBridge 1.0 IrcBridge.qml\nMessageListModel 1.0 MessageListModel.qml\n' \
    > "$tmp/org/kde/kirc/qmldir"

cp "$here"/tst_smoke.qml "$tmp/"

# QT_FORCE_STDERR_LOGGING: without it Qt logs to the journal, not the terminal.
exec env QML2_IMPORT_PATH="$tmp" \
         QT_FORCE_STDERR_LOGGING=1 \
         QT_QPA_PLATFORM="$qpa" \
         "$qmlbin" "$tmp/tst_smoke.qml"
