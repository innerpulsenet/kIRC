#!/bin/sh
# C++ stage of the glass settings contract (p8): builds tst_config_glass.cpp
# against the real cpp/kircconfig.cpp (moc + Qt6 Core/Gui + KF6 ConfigCore and
# Wallet, all already required by the app build) and runs it with a throwaway
# XDG_CONFIG_HOME and no DBus session, so it never touches the user's kirc.conf
# and never opens a wallet.
#
# Usage:  qml-tests/glass-config-test.sh     (also stage "glass-config" of run.sh)
# Exit code: 0 = every check passed.  A missing toolchain is reported as SKIP
# (no failure) so the QML stages stay runnable on a Qt-only machine.
set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

moc=$(command -v moc6 || true)
[ -z "$moc" ] && [ -x /usr/lib64/qt6/libexec/moc ] && moc=/usr/lib64/qt6/libexec/moc
if [ -z "$moc" ] || ! command -v g++ >/dev/null 2>&1 || ! pkg-config --exists Qt6Core; then
    echo "GLASS-CONFIG: SKIPPED (no g++ / moc / Qt6Core pkg-config on this machine)"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$moc" "$root/cpp/kircconfig.h" -o "$tmp/moc_kircconfig.cpp"

# Qt6Gui comes in through KWallet's header (qwindowdefs.h).
# secretstore_kwallet.cpp supplies kirc::makeSecretStore(), which
# kircconfig.cpp has called since the platform-backend split; the null D-Bus
# address below keeps the wallet unavailable so the test exercises the
# memory-only path.
g++ -std=c++17 -fPIC \
    $(pkg-config --cflags Qt6Core Qt6Gui) \
    -I/usr/include/KF6/KConfigCore -I/usr/include/KF6/KConfig -I/usr/include/KF6/KWallet \
    -I"$root/cpp" \
    "$here/tst_config_glass.cpp" "$root/cpp/kircconfig.cpp" "$root/cpp/secretstore_kwallet.cpp" "$tmp/moc_kircconfig.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui) -lKF6ConfigCore -lKF6Wallet \
    -o "$tmp/tst_config_glass"

cfg=$(mktemp -d)
trap 'rm -rf "$tmp" "$cfg"' EXIT
env XDG_CONFIG_HOME="$cfg" DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null" \
    "$tmp/tst_config_glass"
