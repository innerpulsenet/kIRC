// SPDX-License-Identifier: MIT OR Apache-2.0

#include "kircnotify.h"
#include "kircconfig.h"

KircNotifier::KircNotifier(KircConfig *config, QObject *parent)
    : QObject(parent)
    , m_config(config)
    , m_platformReady(kircPlatformNotificationInitialize())
{
}

KircNotifier::~KircNotifier()
{
    if (m_platformReady) {
        kircPlatformNotificationShutdown();
    }
}

void KircNotifier::notify(const QString &title, const QString &body)
{
    if (!m_platformReady) {
        return;
    }
    kircPlatformNotify(title.isEmpty() ? QStringLiteral("kIRC") : title, body);
}

void KircNotifier::notifyClassified(const QString &title, const QString &body, bool isDirect)
{
    if (m_config) {
        const bool allowed = isDirect ? m_config->notifyDirectMessages()
                                      : m_config->notifyHighlights();
        if (!allowed) {
            return;
        }
    }
    notify(title, body);
}
