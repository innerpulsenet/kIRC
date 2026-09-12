// SPDX-License-Identifier: MIT OR Apache-2.0

#include "kircnotify.h"

#include <KNotification>

#include <QIcon>
#include <QPixmap>
#include <QStandardPaths>

namespace {

// Both the event id and the icon are "standard" KDE values:
//  - "message" is the event konversation and neochat use for a chat message,
//    so Plasma's per-event notification settings and Do-Not-Disturb apply to
//    it exactly as they do for those clients.
//  - the icon is the app's own artwork ("kirc") whenever the theme resolves
//    it; a stock name like "preferences-system-network" made every
//    notification show a generic network glyph instead of kirc.png.  The
//    stock name stays as a runtime fallback so a tree without the icons
//    installed still gets one.
constexpr auto kEventId = "message";
constexpr auto kIconName = "kirc";
constexpr auto kIconFallbackName = "preferences-system-network";
constexpr auto kComponentName = "kIRC";

QString notificationIconName()
{
    return QIcon::hasThemeIcon(QString::fromLatin1(kIconName))
        ? QString::fromLatin1(kIconName)
        : QString::fromLatin1(kIconFallbackName);
}

// Where KNotify looks for a component's event declarations.  Note the file is
// named after the component exactly as passed to KNotification (our
// applicationName is "kIRC"), NOT lower-cased — verified with strace: KNotify
// probes knotifications6/kIRC.notifyrc.
constexpr auto kNotifyRc = "knotifications6/kIRC.notifyrc";

} // namespace

KircNotifier::KircNotifier(QObject *parent)
    : QObject(parent)
{
}

bool KircNotifier::messageEventIsConfigured()
{
    // KNotify only presents an event whose id has an [Event/<id>] entry in the
    // component's .notifyrc; an undeclared id is logged ("No event config
    // could be found for event id ...") and then silently dropped, so the
    // notification never reaches the user.  cpp/kirc.notifyrc declares
    // [Event/message], but it only exists once kIRC has been installed — when
    // running straight from a build tree it is absent, and sending "message"
    // would mean highlights produce no notification at all.
    return !QStandardPaths::locate(QStandardPaths::GenericDataLocation, QString::fromUtf8(kNotifyRc)).isEmpty();
}

void KircNotifier::notify(const QString &title, const QString &body)
{
    const QString heading = title.isEmpty() ? QStringLiteral("kIRC") : title;

    // KNotification::event() creates, configures and *fires* the event; the
    // returned object is owned by KNotification and deleted when the popup
    // closes, so there is nothing to send again or delete here.
    if (messageEventIsConfigured()) {
        KNotification::event(QString::fromLatin1(kEventId),
                             heading,
                             body,
                             notificationIconName(),
                             KNotification::CloseOnTimeout,
                             QString::fromLatin1(kComponentName));
    } else {
        // Standard event: always deliverable, and still honours Plasma's
        // Do-Not-Disturb and the user's global notification settings.  (This
        // overload takes no icon name, so it is set on the created event.)
        KNotification *notification = KNotification::event(KNotification::Notification,
                                                           heading,
                                                           body,
                                                           QPixmap(),
                                                           KNotification::CloseOnTimeout);
        if (notification) {
            notification->setIconName(notificationIconName());
        }
    }
}
