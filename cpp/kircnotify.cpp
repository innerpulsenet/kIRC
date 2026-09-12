// SPDX-License-Identifier: MIT OR Apache-2.0

#include "kircnotify.h"

KircNotifier::KircNotifier(QObject *parent)
    : QObject(parent)
{
}

void KircNotifier::notify(const QString &title, const QString &body)
{
    kircPlatformNotify(title.isEmpty() ? QStringLiteral("kIRC") : title, body);
}
