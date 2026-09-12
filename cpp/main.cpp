// SPDX-License-Identifier: MIT OR Apache-2.0
//
// kIRC entry point.
//
// The heavy lifting lives in the Rust crate `kirc` (CXX-Qt bridge) which is
// built by Cargo and linked in as a static library; the QML module
// `org.kde.kirc` is generated/registered there too.
//
// This file adds the KF6 native integration around it:
//   * KircConfig -> KConfig profile in ~/.config/kIRC/kirc.conf,
//   * KircNotifier -> KNotification for IrcBridge::notification_fired,
//   * KircTray -> KStatusNotifierItem (tray icon, unread badge, menu).

#include "kircconfig.h"
#include "kircnotify.h"
#include "kirctray.h"

#include <QApplication>
#include <QCoreApplication>
#include <QIcon>
#include <QList>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QStringLiteral>
#include <QUrl>

#ifdef Q_OS_WIN
// Toast identity: SetCurrentProcessExplicitAppUserModelID lives here.  Same
// Windows-header discipline as the other Windows-only sources
// (cpp/secretstore_windows.cpp): keep windows.h lean and free of min/max.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <shobjidl.h>
#endif

#ifdef Q_OS_WIN
namespace {
// Every size the embedded artwork provides (kirc-windows.qrc); Explorer and
// the taskbar pick their own, so register them all.
QIcon embeddedAppIcon()
{
    QIcon icon;
    for (int size : {16, 22, 24, 32, 48, 64, 128, 256}) {
        icon.addFile(QStringLiteral(":/kirc/icons/%1x%1/kirc.png").arg(size));
    }
    return icon;
}
} // namespace
#endif

int main(int argc, char *argv[])
{
    // KConfig/KNotifications use these to name their config/cache files, so set
    // them before anything else touches them.
    QCoreApplication::setOrganizationName(QStringLiteral("kde"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("kde.org"));
    QCoreApplication::setApplicationName(QStringLiteral("kIRC"));
    QCoreApplication::setApplicationVersion(QStringLiteral(KIRC_VERSION));

#ifdef Q_OS_WIN
    // Toast identity (Phase 5): Windows delivers classic desktop toasts to
    // the AppUserModelID the process registered, so set ours before
    // QApplication exists.  The id must match the one
    // kircPlatformNotify() fires under (cpp/kircnotify_windows.cpp) and the
    // Start-menu shortcut the installer phase creates; running without that
    // shortcut (development/portable runs) means toast creation fails at
    // runtime and the notification backend degrades to its logged fallback.
    // Only fails on a malformed id, so the HRESULT can be ignored.
    SetCurrentProcessExplicitAppUserModelID(L"org.kde.kirc");
#endif

#ifdef Q_OS_WIN
    // Qt Quick backend (Windows): software rendering is the DEFAULT.
    //
    // Rationale: kIRC's UI is repaint-idle — a terminal pane that redraws on
    // arrival, not per frame — so the GPU mostly idles behind a D3D11
    // swapchain that still costs startup time, battery and driver surface.
    // The raster renderer is also the most predictable path across old
    // hardware, remote-desktop/RDP sessions and machines with broken or
    // blocklisted GPU drivers.  The trade is honest: the shader-based glass
    // frost cannot run on the software scene graph, so the QML side detects
    // it (ThemeEngine.effectsSupported, fed from the window's GraphicsInfo)
    // and degrades the effects to plain underlays instead of a broken or
    // silently missing render.
    //
    // KIRC_QUICK_BACKEND is the supported development knob for bringing a
    // hardware backend back (must be set before QApplication constructs its
    // platform integration, hence this place):
    //   software -> Qt Quick software renderer (what the default does anyway)
    //   d3d11    -> RHI over Direct3D 11
    //   opengl   -> RHI over OpenGL
    // Anything else warns once and falls through to Qt's own default.
    if (qEnvironmentVariableIsSet("KIRC_QUICK_BACKEND")) {
        const QByteArray quickBackend = qgetenv("KIRC_QUICK_BACKEND");
        if (quickBackend == "software") {
            qputenv("QT_QUICK_BACKEND", "software");
        } else if (quickBackend == "d3d11") {
            qputenv("QSG_RHI_BACKEND", "d3d11");
        } else if (quickBackend == "opengl") {
            qputenv("QSG_RHI_BACKEND", "opengl");
        } else {
            qWarning("kIRC: unknown KIRC_QUICK_BACKEND='%s'; using Qt's default backend",
                     quickBackend.constData());
        }
    } else {
        qputenv("QT_QUICK_BACKEND", "software");
    }
#endif

    QApplication app(argc, argv);

#ifdef Q_OS_WIN
    // Windows has no freedesktop icon theme to resolve "kirc"; the embedded
    // artwork is the only reliable source for the window/taskbar icon.
    app.setWindowIcon(embeddedAppIcon());
#else
    // Window/taskbar/tray icon.  KWin prefers the window's own icon and only
    // falls back to the desktop entry, so without this the title bar shows a
    // generic glyph whenever the launcher/WM can't resolve the app id.
    // Prefer the app's own artwork; fall back to the stock KDE name so a dev
    // tree without the icons installed still gets an icon (never a null one).
    QIcon appIcon = QIcon::fromTheme(QStringLiteral("kirc"));
    if (appIcon.isNull()) {
        appIcon = QIcon::fromTheme(QStringLiteral("preferences-system-network"));
    }
    app.setWindowIcon(appIcon);
#endif
    // Ties the window to kIRC.desktop on Wayland, where the app id (not the
    // window icon) is what the compositor matches against.  Harmless
    // elsewhere.
    app.setDesktopFileName(QStringLiteral("kIRC"));

    // Must be set before the QML engine is created so Kirigami picks up the
    // style.  An explicit override wins (development aid only — not a
    // supported knob).
    if (const QByteArray styleOverride = qgetenv("KIRC_QUICKCONTROLS_STYLE");
        !styleOverride.isEmpty()) {
        QQuickStyle::setStyle(QString::fromLocal8Bit(styleOverride));
    } else {
#ifdef Q_OS_WIN
        // The Windows port ships the Basic style: kIRC's controls are
        // extensively customized (backgrounds/content items), so the
        // uncustomized parts just need a predictable, dependency-free base.
        // org.kde.desktop (qqc2-desktop-style) is the Linux default and a
        // possible Windows alternative, but it is not part of the shipped
        // dependency set.
        QQuickStyle::setStyle(QStringLiteral("Basic"));
#else
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));
#endif
    }

    // Read the persisted profile before the engine exists, so the connection
    // form is prefilled on its first paint.
    KircConfig config;
    config.load();

    // Created before the engine too, so `kircTray` can be a context property
    // from the start (QML bindings on it then track host availability live).
    // The window and bridge only exist after engine.load(), hence attach().
    KircTray tray(&config);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("kircConfig"), &config);
    engine.rootContext()->setContextProperty(QStringLiteral("kircTray"), &tray);

    // Surface QML warnings even when Qt's default logging rules would hide them.
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::warnings,
        &app,
        [](const QList<QQmlError> &warnings) {
            for (const QQmlError &warning : warnings) {
                qWarning("QML: %s", qPrintable(warning.toString()));
            }
        });

    const QUrl url(QStringLiteral("qrc:/qt/qml/org/kde/kirc/qml/main.qml"));
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreated,
        &app,
        [url](QObject *object, const QUrl &objectUrl) {
            if (!object && url == objectUrl) {
                qCritical("kIRC: failed to load %s", qPrintable(url.toString()));
                QCoreApplication::exit(-1);
            }
        },
        Qt::QueuedConnection);

    engine.load(url);

    // The terminal font family is a ThemeEngine-level override (the theme file
    // only carries its default). main.qml restores the theme id and the font
    // delta on its own; the family is applied here because the singleton is
    // reachable from C++ and this keeps the choice effective from the first
    // frame. A harness or a build without the singleton simply skips this.
    if (QObject *themeEngine = engine.singletonInstance<QObject *>(
            QStringLiteral("org.kde.kirc"), QStringLiteral("ThemeEngine"))) {
        if (themeEngine->property("fontFamilyOverride").isValid()) {
            themeEngine->setProperty("fontFamilyOverride", config.fontFamily());
        }
    }

    // The bridge is instantiated by QML, so the only handle C++ has on it is
    // the objectName it sets (main.qml: `IrcBridge { objectName: "ircBridge" }`).
    // Reaching in by name is less invasive than exporting it through the
    // engine's root context and keeps QML as the owner of the object.
    QObject *rootObject = engine.rootObjects().value(0);
    auto *window = qobject_cast<QQuickWindow *>(rootObject);
    QObject *bridge =
        rootObject ? rootObject->findChild<QObject *>(QStringLiteral("ircBridge")) : nullptr;

    KircNotifier notifier;
    if (bridge) {
        // String-based connect on purpose: IrcBridge is a cxx-qt generated
        // type and its signals are only reachable through the meta-object
        // (see cpp/kircnotify.h for why there is no lambda overload here).
        const bool connected = QObject::connect(bridge,
                                                SIGNAL(notification_fired(QString, QString)),
                                                &notifier,
                                                SLOT(notify(QString, QString)));
        if (!connected) {
            qWarning("kIRC: could not route notification_fired to KNotification");
        }
    } else {
        qWarning("kIRC: IrcBridge not found; native notifications and the tray are disabled");
    }

    tray.attach(window, bridge);

    return app.exec();
}
