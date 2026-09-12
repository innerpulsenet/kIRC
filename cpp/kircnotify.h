// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircNotifier — turns IrcBridge::notification_fired() into native desktop
// notifications.  Platform delivery lives in kircnotify_linux.cpp
// (KNotification) and kircnotify_windows.cpp (native toasts in a later port
// phase; until then a logged stub).
//
// Why a QObject with a slot instead of a lambda in main(): IrcBridge is a
// cxx-qt generated type, so its signals are only reachable through Qt's
// string-based meta-object connect (SIGNAL(...)), which requires a slot — it
// has no overload taking a functor.  Pulling in the generated
// kirc/src/bridge.cxxqt.h header just to get typed signal pointers would drag
// the whole cxx-qt/rust glue into main.cpp, which is not worth it for one
// connection.

#pragma once

#include <QObject>
#include <QString>

class KircConfig;

class KircNotifier : public QObject
{
    Q_OBJECT

public:
    explicit KircNotifier(KircConfig *config, QObject *parent = nullptr);
    ~KircNotifier() override;

public Q_SLOTS:
    /// Connected to IrcBridge::notification_fired(title, body).  The bridge
    /// already decides what deserves a notification (highlights and private
    /// messages); this only renders it.
    void notify(const QString &title, const QString &body);
    void notifyClassified(const QString &title, const QString &body, bool isDirect);

private:
    KircConfig *m_config = nullptr;
    bool m_platformReady = false;
};

/// Platform delivery for a resolved (heading, body) pair.  Implemented once
/// per platform; no KDE types cross this boundary.
void kircPlatformNotify(const QString &heading, const QString &body);
bool kircPlatformNotificationInitialize();
void kircPlatformNotificationShutdown();
