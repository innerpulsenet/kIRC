# SPDX-License-Identifier: MIT OR Apache-2.0
#
# kIRC — KDE Kirigami IRCv3 client.
#
# Layout:
#   rust/core   pure-Rust IRC engine (crate `kirc-core`), built by that dir's owner
#   rust/       CXX-Qt bridge crate (crate `kirc`), built by Cargo, linked as a static lib
#   rust/qml    QML files of the `org.kde.kirc` QML module
#   cpp/        C++ shell (main.cpp)

cmake_minimum_required(VERSION 3.24)

project(kIRC
    VERSION 0.1.0
    DESCRIPTION "KDE Kirigami IRCv3 client"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

include(GNUInstallDirs)

# ---------------------------------------------------------------------------
# Qt 6
# ---------------------------------------------------------------------------
find_package(Qt6 6.6 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
    DBus
    Qml
    Quick
    QuickControls2
    QmlImportScanner
)

# ---------------------------------------------------------------------------
# KDE Frameworks 6
#
# Fedora does not ship the KF6 umbrella package, so fall back to the
# per-framework packages (KF6Kirigami, KF6Config, KF6Notifications,
# KF6StatusNotifierItem).
#
# NOTE: in KF6, KStatusNotifierItem is no longer part of KNotifications — it
# moved into its own framework, so the tray needs KF6StatusNotifierItem.
# ---------------------------------------------------------------------------
find_package(KF6 QUIET COMPONENTS Kirigami Config Notifications StatusNotifierItem Wallet)

if(NOT TARGET KF6::Kirigami)
    find_package(KF6Kirigami REQUIRED)
endif()
if(NOT TARGET KF6::ConfigCore)
    find_package(KF6Config REQUIRED)
endif()
if(NOT TARGET KF6::Notifications)
    find_package(KF6Notifications REQUIRED)
endif()
if(NOT TARGET KF6::StatusNotifierItem)
    find_package(KF6StatusNotifierItem REQUIRED)
endif()
if(NOT TARGET KF6::Wallet)
    find_package(KF6Wallet REQUIRED)
endif()

if(TARGET KF6::ConfigCore)
    set(KIRC_KCONFIG_TARGET KF6::ConfigCore)
elseif(TARGET KF6::Config)
    set(KIRC_KCONFIG_TARGET KF6::Config)
else()
    message(FATAL_ERROR "kIRC: no KF6 KConfig target found")
endif()

# ---------------------------------------------------------------------------
# CXX-Qt (provides cxx_qt_import_crate / cxx_qt_import_qml_module)
# ---------------------------------------------------------------------------
find_package(CxxQt QUIET)
if(NOT CxxQt_FOUND)
    include(FetchContent)
    FetchContent_Declare(CxxQt
        GIT_REPOSITORY https://github.com/kdab/cxx-qt-cmake.git
        GIT_TAG 0.10.0
        GIT_SHALLOW TRUE
    )
    FetchContent_MakeAvailable(CxxQt)
endif()

# cxx-qt-build shells out to `qmake` to locate Qt; make sure CMake and Cargo
# agree on which Qt that is.
find_program(KIRC_QMAKE_EXECUTABLE NAMES qmake6 qmake)
if(KIRC_QMAKE_EXECUTABLE)
    set(KIRC_QMAKE_ARGS QMAKE "${KIRC_QMAKE_EXECUTABLE}")
endif()

# ---------------------------------------------------------------------------
# The Rust bridge crate (`kirc`) and its QML module (`org.kde.kirc`)
# ---------------------------------------------------------------------------
cxx_qt_import_crate(
    MANIFEST_PATH rust/Cargo.toml
    CRATES kirc
    QT_MODULES Qt::Core Qt::Gui Qt::Qml Qt::Quick Qt::QuickControls2
    ${KIRC_QMAKE_ARGS}
)

cxx_qt_import_qml_module(kirc_qml
    URI "org.kde.kirc"
    SOURCE_CRATE kirc
)

# ---------------------------------------------------------------------------
# The application
# ---------------------------------------------------------------------------
qt_add_executable(kIRC
    cpp/main.cpp
    cpp/kircconfig.cpp
    cpp/kircconfig.h
    cpp/kircnotify.cpp
    cpp/kircnotify.h
    cpp/kirctray.cpp
    cpp/kirctray.h
)

target_link_libraries(kIRC PRIVATE
    kirc_qml
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::DBus
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    KF6::Kirigami
    KF6::Notifications
    KF6::StatusNotifierItem
    KF6::Wallet
    ${KIRC_KCONFIG_TARGET}
)

install(TARGETS kIRC RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# KNotify only delivers an event id that is declared for the component, so the
# `message` event used by cpp/kircnotify.cpp must be installed next to the
# notifications data.  Without it KircNotifier falls back to the standard
# Notification event (see cpp/kircnotify.cpp), but the chat-specific event —
# and with it per-event configuration in System Settings — needs this file.
install(FILES cpp/kIRC.notifyrc DESTINATION ${CMAKE_INSTALL_DATADIR}/knotifications6)

# ---------------------------------------------------------------------------
# Desktop integration.  Without these a `cmake --install` produced a binary
# with no menu entry and no icon, so the window fell back to a generic glyph.
# ---------------------------------------------------------------------------
install(FILES packaging/kIRC.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES packaging/org.kde.kirc.metainfo.xml DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
install(FILES packaging/kirc.svg
        DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)
foreach(_size 16 22 24 32 48 64 128 256)
    install(FILES packaging/icons/hicolor/${_size}x${_size}/apps/kirc.png
            DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/${_size}x${_size}/apps)
endforeach()
