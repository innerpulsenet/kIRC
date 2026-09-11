// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircNotifier — turns IrcBridge::notification_fired() into native desktop
// notifications via KNotification.
//
// Why a QObject with a slot instead of a lambda in main(): IrcBridge is a
// cxx-qt generated type, so its signals are only reachable through Qt's
// string-based meta-object connect (SIGNAL(...)), which requires a slot — it
// has no overload taking a functor.  Pulling in the generated
// kirc/src/bridge.cxxqt.h header just to get typed signal pointers would drag
// the whole cxx-qt/rrust glue into main.cpp, which is not worth it for one
// connection.

#pragma once

#include <QObject>
#include <QString>

class KircNotifier : public QObject
{
    Q_OBJECT

public:
    explicit KircNotifier(QObject *parent = nullptr);

public Q_SLOTS:
    /// Connected to IrcBridge::notification_fired(title, body).  The bridge
    /// already decides what deserves a notification (highlights and private
    /// messages); this only renders it.
    void notify(const QString &title, const QString &body);

private:
    /// Whether our `message` event is actually declared to KNotify (see the
    /// .cpp); decides which KNotification overload to use.
    static bool messageEventIsConfigured();
};
