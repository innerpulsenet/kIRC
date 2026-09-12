// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Linux tray backend: KStatusNotifierItem over D-Bus.  Behaviour-preserving
// port of the code that used to live directly in kirctray.cpp: same item
// setup, same icon-name resolution, same StatusNotifierWatcher probe.

#include "kirctraybackend.h"

#include <KStatusNotifierItem>

#include <QAction>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusServiceWatcher>
#include <QIcon>
#include <QMenu>
#include <QQuickWindow>

namespace {

// The app's own artwork first: a stock KDE name ("preferences-system-network")
// is EXACTLY why the tray kept showing a generic network glyph no matter what
// was installed — the theme resolves the stock name and never looks at
// kirc.png.  Use "kirc" whenever the icon theme can resolve it, and fall back
// to the old stock name so a dev tree without icons installed still gets one.
constexpr auto kTrayIconName = "kirc";
constexpr auto kTrayIconFallbackName = "preferences-system-network";

QString trayIconName()
{
    return QIcon::hasThemeIcon(QString::fromLatin1(kTrayIconName))
        ? QString::fromLatin1(kTrayIconName)
        : QString::fromLatin1(kTrayIconFallbackName);
}

// D-Bus coordinates of the StatusNotifierItem watcher, used only to answer
// "is there actually a tray host (Plasma panel) to get the window back from?".
constexpr auto kWatcherService = "org.kde.StatusNotifierWatcher";
constexpr auto kWatcherPath = "/StatusNotifierWatcher";
constexpr auto kWatcherInterface = "org.kde.StatusNotifierWatcher";

class StatusNotifierBackend final : public KircTrayBackend
{
    Q_OBJECT

public:
    StatusNotifierBackend()
    {
        m_item = new KStatusNotifierItem(QStringLiteral("kIRC"), this);
        m_item->setCategory(KStatusNotifierItem::Communications);
        m_item->setStatus(KStatusNotifierItem::Active);
        // The same name drives the pixmap and the tooltip's icon lookup, so
        // both stay consistent with whatever trayIconName() resolved.
        m_iconName = trayIconName();
        m_item->setIconByName(m_iconName);
        m_item->setTitle(QStringLiteral("kIRC"));
        m_item->setToolTip(m_iconName, QStringLiteral("kIRC"), tr("IRC client"));
        // The whole menu is provided by the facade; the standard actions
        // (which include a plain Quit) cannot implement hide-to-tray.
        m_item->setStandardActionsEnabled(false);

        // The watcher may appear or disappear (panel restart, another session
        // that owns the name), so re-probe instead of trusting the startup
        // value.
        auto *watcher = new QDBusServiceWatcher(QString::fromLatin1(kWatcherService),
                                                QDBusConnection::sessionBus(),
                                                QDBusServiceWatcher::WatchForRegistration
                                                    | QDBusServiceWatcher::WatchForUnregistration,
                                                this);
        connect(watcher, &QDBusServiceWatcher::serviceRegistered,
                this, &StatusNotifierBackend::refreshAvailability);
        connect(watcher, &QDBusServiceWatcher::serviceUnregistered,
                this, &StatusNotifierBackend::refreshAvailability);

        refreshAvailability();
    }

    QMenu *menu() override
    {
        return m_item->contextMenu();
    }

    void attach(QQuickWindow *window) override
    {
        if (m_item && window) {
            // Lets KStatusNotifierItem's own activate() (tray left-click)
            // toggle the window for us, including raising it.
            m_item->setAssociatedWindow(window);
        }
    }

    void setIndicators(int unread, const QString &tooltipSubtitle) override
    {
        if (!m_item) {
            return;
        }

        if (unread > 0) {
            m_item->setOverlayIconByPixmap(
                QIcon(kircUnreadBadgePixmap(22, unread)));
            m_item->setStatus(KStatusNotifierItem::NeedsAttention);
        } else {
            // An empty icon removes the overlay again.
            m_item->setOverlayIconByPixmap(QIcon());
            m_item->setStatus(KStatusNotifierItem::Active);
        }

        m_item->setToolTip(m_iconName, QStringLiteral("kIRC"), tooltipSubtitle);
    }

    bool isAvailable() const override
    {
        return m_available;
    }

private:
    void refreshAvailability()
    {
        bool available = false;

        const QDBusConnection bus = QDBusConnection::sessionBus();
        // isServiceRegistered() reads the connection's cached name-owner table,
        // so it is cheap and never blocks; the property read only happens once
        // the watcher is known to exist.
        if (bus.isConnected()
            && bus.interface()->isServiceRegistered(QString::fromLatin1(kWatcherService))) {
            const QDBusInterface watcher(QString::fromLatin1(kWatcherService),
                                         QString::fromLatin1(kWatcherPath),
                                         QString::fromLatin1(kWatcherInterface),
                                         bus);
            if (watcher.isValid()) {
                available = watcher.property("IsStatusNotifierHostRegistered").toBool();
            }
        }

        if (m_available != available) {
            m_available = available;
            qInfo("kIRC: StatusNotifierItem host %s",
                  available ? "registered" : "not registered");
            Q_EMIT availabilityChanged(available);
        }
    }

    KStatusNotifierItem *m_item = nullptr;
    QString m_iconName;
    bool m_available = false;
};

} // namespace

std::unique_ptr<KircTrayBackend> makeKircTrayBackend()
{
    return std::make_unique<StatusNotifierBackend>();
}

#include "kirctray_linux.moc"
