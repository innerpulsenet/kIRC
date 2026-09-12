// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Windows notification backend — Phase 2 stub.
//
// Native delivery (classic desktop toasts with a stable AppUserModelID and
// proper DND/Focus-Assist behaviour) is the dedicated notification phase of
// the Windows port; until that lands, notifications are logged so the
// feature is visibly wired end to end without pretending to be native.
// A tray-message fallback is deliberately NOT used here: it would show a
// balloon that Windows may suppress anyway and would duplicate whatever the
// toast backend later does.

#include "kircnotify.h"

void kircPlatformNotify(const QString &heading, const QString &body)
{
    qInfo("kIRC: notification: %s: %s", qPrintable(heading), qPrintable(body));
}
