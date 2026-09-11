# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Fedora RPM spec for kIRC, a KDE Kirigami IRCv3 client.
#
# The application is a CXX-Qt hybrid: a Rust cargo workspace (rust/) builds a
# static library, CMake links it into a Qt 6 / QML executable.  Two things make
# a "normal" network-enabled build undesirable, so both are vendored here:
#
#   * CMakeLists.txt FetchContent's cxx-qt-cmake at *configure* time.
#     We ship it as Source1 and point FETCHCONTENT_SOURCE_DIR_CXXQT at the
#     unpacked directory, so no network access is needed.
#   * Cargo would otherwise hit crates.io.  We ship a full `cargo vendor` tree
#     as Source2 and wire CARGO_HOME to an offline source-replacement config.
#
# See packaging/README.md for how to (re)generate Source2 and the source
# tarball.  With both in place `rpmbuild -ba` works with the network unplugged.

# `cargo vendor` output tree, shipped as Source2.
%global vendor_tarball %{name}-vendor-%{version}.tar.gz
# Unpacked name of Source1 (cxx-qt-cmake GitHub archive).
%global cxxqt_dir cxx-qt-cmake-0.10.0

Name:           kirc
Version:        0.1.0
Release:        1%{?dist}
Summary:        KDE Kirigami IRCv3 client

# UI (QML) is GPL-2.0-or-later; the Rust engine, CXX-Qt bridge and C++ shell
# are MIT OR Apache-2.0 (see the SPDX headers and the crates' manifests).
License:        GPL-2.0-or-later AND MIT AND Apache-2.0
URL:            https://github.com/innerpulsenet/kIRC

# git archive of the source tree, including rust/Cargo.lock (see README).
Source0:        %{name}-%{version}.tar.gz
# https://github.com/kdab/cxx-qt-cmake/archive/refs/tags/0.10.0.tar.gz
Source1:        cxx-qt-cmake-0.10.0.tar.gz
# `cd rust && cargo vendor` output, packaged with a top-level vendor/ dir.
Source2:        %{vendor_tarball}

BuildRequires:  cmake
BuildRequires:  gcc-c++
BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  kf6-kirigami-devel
BuildRequires:  kf6-kconfig-devel
BuildRequires:  kf6-knotifications-devel
BuildRequires:  kf6-kstatusnotifieritem-devel
BuildRequires:  kf6-kwallet-devel
BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

# Qt Quick Controls ship inside qt6-qtdeclarative on Fedora; the Kirigami
# "desktop" style lives in kf6-qqc2-desktop-style (set via QQuickStyle in
# cpp/main.cpp), and the KF6 frameworks back settings, tray and notifications.
Requires:       qt6-qtbase
Requires:       qt6-qtdeclarative
Requires:       kf6-qqc2-desktop-style
Requires:       kf6-kirigami
Requires:       kf6-kconfig
Requires:       kf6-knotifications
Requires:       kf6-kstatusnotifieritem
Requires:       kf6-kwallet

%description
kIRC is an IRCv3 client for the KDE Plasma desktop.  The interface is built
with Kirigami, so it follows your Plasma color scheme and fonts and adapts
from a desktop window to a narrow panel or a touch device.

The protocol engine is a pure-Rust core (kirc-core) that speaks IRCv3,
including message tags, capability negotiation (CAP) and SASL authentication
(PLAIN, SCRAM-SHA-256 and EXTERNAL) over TLS.  The Qt Quick user interface
talks to that engine through CXX-Qt.

Features include multiple server connections, channel and query views,
nickname and topic handling, and desktop notifications for highlights.

%prep
%setup -q -a 1 -a 2

# Offline cargo: replace crates.io with the vendored tree.  Using a dedicated
# CARGO_HOME keeps the config independent of the build cwd and avoids touching
# the builder's real ~/.cargo.
mkdir -p %{_builddir}/cargo-home
cat > %{_builddir}/cargo-home/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "%{_builddir}/%{name}-%{version}/vendor"

[net]
offline = true
EOF

%build
export CARGO_HOME=%{_builddir}/cargo-home
export CARGO_NET_OFFLINE=true

%cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DFETCHCONTENT_SOURCE_DIR_CXXQT=%{_builddir}/%{name}-%{version}/%{cxxqt_dir}
%cmake_build

%install
%cmake_install

# Desktop entry
desktop-file-install --dir=%{buildroot}%{_datadir}/applications \
    packaging/kIRC.desktop

# AppStream metadata
install -Dpm 0644 packaging/org.kde.kirc.metainfo.xml \
    %{buildroot}%{_datadir}/metainfo/org.kde.kirc.metainfo.xml

# Icons (hicolor theme)
install -Dpm 0644 packaging/kirc.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/kirc.svg
for size in 16 22 24 32 48 64 128 256; do
    install -Dpm 0644 \
        packaging/icons/hicolor/${size}x${size}/apps/kirc.png \
        %{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps/kirc.png
done

%check
# No compiled test suite is shipped, but the installed metadata must be valid.
desktop-file-validate packaging/kIRC.desktop
appstream-util validate-relax packaging/org.kde.kirc.metainfo.xml

%files
%license LICENSES.md
%{_bindir}/kIRC
%{_datadir}/applications/kIRC.desktop
%{_datadir}/metainfo/org.kde.kirc.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/kirc.svg
%{_datadir}/icons/hicolor/*/apps/kirc.png
%{_datadir}/knotifications6/kIRC.notifyrc
%doc packaging/README.md

%changelog
* Fri Sep 11 2026 The kIRC Authors <kirc@innerpulse.net> - 0.1.0-1
- Initial package
