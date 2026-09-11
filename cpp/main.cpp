// SPDX-License-Identifier: MIT OR Apache-2.0
//
// kIRC entry point.
//
// The heavy lifting lives in the Rust crate `kirc` (CXX-Qt bridge) which is
// built by Cargo and linked in as a static library; the QML module
// `org.kde.kirc` is generated/registered there too.

#include <QApplication>
#include <QCoreApplication>
#include <QList>
#include <QQmlApplicationEngine>
#include <QQmlError>
#include <QQuickStyle>
#include <QStringLiteral>
#include <QUrl>

int main(int argc, char *argv[])
{
    // KConfig/KNotifications use these to name their config/cache files, so set
    // them before anything else touches them.
    QCoreApplication::setOrganizationName(QStringLiteral("kde"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("kde.org"));
    QCoreApplication::setApplicationName(QStringLiteral("kIRC"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    QApplication app(argc, argv);

    // Must be set before the QML engine is created so that Kirigami picks up
    // qqc2-desktop-style.
    QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));

    QQmlApplicationEngine engine;

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

    return app.exec();
}
