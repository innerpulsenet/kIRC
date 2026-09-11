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
    Qml
    Quick
    QuickControls2
    QmlImportScanner
)

# ---------------------------------------------------------------------------
# KDE Frameworks 6
#
# Fedora does not ship the KF6 umbrella package, so fall back to the
# per-framework packages (KF6Kirigami, KF6Config, KF6Notifications).
# ---------------------------------------------------------------------------
find_package(KF6 QUIET COMPONENTS Kirigami Config Notifications)

if(NOT TARGET KF6::Kirigami)
    find_package(KF6Kirigami REQUIRED)
endif()
if(NOT TARGET KF6::ConfigCore)
    find_package(KF6Config REQUIRED)
endif()
if(NOT TARGET KF6::Notifications)
    find_package(KF6Notifications REQUIRED)
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
)

target_link_libraries(kIRC PRIVATE
    kirc_qml
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    KF6::Kirigami
    KF6::Notifications
    ${KIRC_KCONFIG_TARGET}
)

install(TARGETS kIRC RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
