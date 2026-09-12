#!/bin/sh
# Runtime smoke test for the kIRC QML UI.
#
# Builds a temporary org.kde.kirc module out of the real qml/ files plus the
# cxx-qt test doubles in this directory, then runs tst_smoke.qml and
# tst_cmds.qml headless.
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
cp "$root"/rust/qml/*.qml "$root"/rust/qml/Theme.js "$tmp/org/kde/kirc/"
cp -r "$root"/rust/qml/themes "$tmp/org/kde/kirc/"
cp "$here"/IrcBridge.qml "$here"/MessageListModel.qml "$tmp/org/kde/kirc/"

# qmldir mirroring the one cxx-qt generates for the real module
# (build/cxxqt/qml_modules/org/kde/kirc/qmldir): the cxx-qt Rust types plus
# every QML file in rust/qml/, so main.qml can use ConnectPage/ChatPage as
# types rather than only via file URLs.
printf 'module org.kde.kirc\nsingleton ThemeEngine 1.0 ThemeEngine.qml\nIrcBridge 1.0 IrcBridge.qml\nMessageListModel 1.0 MessageListModel.qml\nChatPage 1.0 ChatPage.qml\nConnectPage 1.0 ConnectPage.qml\nMessageDelegate 1.0 MessageDelegate.qml\n' \
    > "$tmp/org/kde/kirc/qmldir"

cp "$here"/tst_smoke.qml "$here"/tst_cmds.qml "$here"/tst_scroll.qml "$tmp/"

# QT_FORCE_STDERR_LOGGING: without it Qt logs to the journal, not the terminal.
run_qml() {
    env QML2_IMPORT_PATH="$tmp" \
        QT_FORCE_STDERR_LOGGING=1 \
        QT_QPA_PLATFORM="$qpa" \
        "$qmlbin" "$1"
}

# Stage 1: the UI smoke flow.
# Stage 2: the slash-command contract — each command's wire line, /help
# output, malformed-argument rejection and command tab-completion, asserted
# on the recording bridge double.
# Stage 3: follow-the-tail autoscroll — position-based assertions that the
# log stays pinned while following (including a row whose delegate height
# resolves after insertion), that appends never yank a scrolled-up user,
# and that the pill / a manual return / a buffer switch recover following.
#
# Stage 0 (python, no QML runtime needed): the theme token-completeness check —
# every built-in theme file and the Theme.js mirror must define EXACTLY the
# engine's token table (missing or extra token => FAIL), agree on every value,
# carry the current schema version, and pass the palette contrast /
# distinguishability floors.
status=0
python3 "$here/check-theme-tokens.py" || status=1
run_qml "$tmp/tst_smoke.qml" || status=1
run_qml "$tmp/tst_cmds.qml" || status=1
run_qml "$tmp/tst_scroll.qml" || status=1
exit "$status"
