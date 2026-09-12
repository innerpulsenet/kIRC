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

int main(int argc, char *argv[])
{
    // KConfig/KNotifications use these to name their config/cache files, so set
    // them before anything else touches them.
    QCoreApplication::setOrganizationName(QStringLiteral("kde"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("kde.org"));
    QCoreApplication::setApplicationName(QStringLiteral("kIRC"));
    QCoreApplication::setApplicationVersion(QStringLiteral(KIRC_VERSION));

    QApplication app(argc, argv);

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
    // Ties the window to kIRC.desktop on Wayland, where the app id (not the
    // window icon) is what the compositor matches against.
    app.setDesktopFileName(QStringLiteral("kIRC"));

    // Must be set before the QML engine is created so that Kirigami picks up
    // qqc2-desktop-style.
    QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));

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
