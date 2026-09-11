// SPDX-License-Identifier: MIT OR Apache-2.0

#include "kirctray.h"

#include "kircconfig.h"

#include <KStatusNotifierItem>

#include <QAction>
#include <QColor>
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusServiceWatcher>
#include <QFont>
#include <QIcon>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QQuickWindow>
#include <QVariant>

namespace {

// A communicator app, so Plasma groups it with chat clients.
constexpr auto kTrayIconName = "preferences-system-network";

// D-Bus coordinates of the StatusNotifierItem watcher, used only to answer
// "is there actually a tray host (Plasma panel) to get the window back from?".
constexpr auto kWatcherService = "org.kde.StatusNotifierWatcher";
constexpr auto kWatcherPath = "/StatusNotifierWatcher";
constexpr auto kWatcherInterface = "org.kde.StatusNotifierWatcher";

/// Small round counter badge, drawn in code so no icon theme asset is needed.
QIcon unreadBadgeIcon(int unread)
{
    constexpr int size = 22;
    QPixmap pixmap(size, size);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setRenderHint(QPainter::TextAntialiasing, true);
    painter.setPen(Qt::NoPen);
    painter.setBrush(QColor(0xda, 0x32, 0x2c)); // Breeze negative/red
    painter.drawEllipse(0, 0, size, size);

    QFont font = painter.font();
    font.setBold(true);
    font.setPixelSize(size - (unread > 9 ? 9 : 6));
    painter.setFont(font);
    painter.setPen(Qt::white);
    painter.drawText(pixmap.rect(), Qt::AlignCenter,
                     unread > 99 ? QStringLiteral("99+") : QString::number(unread));
    painter.end();

    return QIcon(pixmap);
}

} // namespace

KircTray::KircTray(KircConfig *config, QObject *parent)
    : QObject(parent)
    , m_config(config)
{
    m_item = new KStatusNotifierItem(QStringLiteral("kIRC"), this);
    m_item->setCategory(KStatusNotifierItem::Communications);
    m_item->setStatus(KStatusNotifierItem::Active);
    m_item->setIconByName(QString::fromLatin1(kTrayIconName));
    m_item->setTitle(QStringLiteral("kIRC"));
    m_item->setToolTip(QString::fromLatin1(kTrayIconName), QStringLiteral("kIRC"), tr("IRC client"));

    // We provide the whole menu ourselves (Show/Hide, Connect, Disconnect,
    // Quit) because the standard "Quit" action cannot implement hide-to-tray.
    m_item->setStandardActionsEnabled(false);

    m_menu = m_item->contextMenu();
    m_showHideAction = m_menu->addAction(tr("Hide kIRC"));
    m_showHideAction->setIcon(QIcon::fromTheme(QStringLiteral("window-restore")));
    m_menu->addSeparator();
    m_connectAction = m_menu->addAction(tr("Connect"));
    m_connectAction->setIcon(QIcon::fromTheme(QStringLiteral("network-connect")));
    m_disconnectAction = m_menu->addAction(tr("Disconnect"));
    m_disconnectAction->setIcon(QIcon::fromTheme(QStringLiteral("network-disconnect")));
    m_menu->addSeparator();
    m_quitAction = m_menu->addAction(tr("Quit kIRC"));
    m_quitAction->setIcon(QIcon::fromTheme(QStringLiteral("application-exit")));

    connect(m_showHideAction, &QAction::triggered, this, &KircTray::onShowHide);
    connect(m_connectAction, &QAction::triggered, this, &KircTray::onConnect);
    connect(m_disconnectAction, &QAction::triggered, this, &KircTray::onDisconnect);
    connect(m_quitAction, &QAction::triggered, this, &KircTray::onQuit);

    // The watcher may appear or disappear (panel restart, another session that
    // owns the name), so re-probe instead of trusting the startup value.
    auto *watcher = new QDBusServiceWatcher(QString::fromLatin1(kWatcherService),
                                            QDBusConnection::sessionBus(),
                                            QDBusServiceWatcher::WatchForRegistration
                                                | QDBusServiceWatcher::WatchForUnregistration,
                                            this);
    connect(watcher, &QDBusServiceWatcher::serviceRegistered, this, &KircTray::refreshAvailability);
    connect(watcher, &QDBusServiceWatcher::serviceUnregistered, this, &KircTray::refreshAvailability);

    refreshAvailability();
}

KircTray::~KircTray() = default;

bool KircTray::isAvailable() const
{
    return m_available;
}

void KircTray::refreshAvailability()
{
    bool available = false;

    const QDBusConnection bus = QDBusConnection::sessionBus();
    // isServiceRegistered() reads the connection's cached name-owner table, so
    // it is cheap and never blocks; the property read only happens once the
    // watcher is known to exist.
    if (bus.isConnected() && bus.interface()->isServiceRegistered(QString::fromLatin1(kWatcherService))) {
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
        qInfo("kIRC: StatusNotifierItem host %s", available ? "registered" : "not registered");
        Q_EMIT availableChanged();
    }
}

void KircTray::attach(QQuickWindow *window, QObject *bridge)
{
    m_window = window;
    m_bridge = bridge;

    if (m_item && m_window) {
        // Lets KStatusNotifierItem's own activate() (tray left-click) toggle
        // the window for us, including raising it.
        m_item->setAssociatedWindow(m_window);
        connect(m_window, &QWindow::visibleChanged, this, &KircTray::updateShowHideAction);
    }

    if (m_bridge) {
        // String-based SIGNAL/SLOT connect on purpose: IrcBridge is a cxx-qt
        // generated type, and including its generated C++ header here would
        // drag the whole cxx-qt/rust glue into this translation unit.  The
        // meta-object route keeps this file independent of it.
        const bool unreadOk =
            connect(m_bridge, SIGNAL(unread_countChanged()), this, SLOT(onUnreadCountChanged()));
        const bool stateOk = connect(m_bridge, SIGNAL(state_changed(int)), this, SLOT(onStateChanged()));
        if (!unreadOk || !stateOk) {
            qWarning("kIRC: could not connect tray to IrcBridge signals");
        }
    }

    updateShowHideAction();
    updateIndicators();
}

void KircTray::updateShowHideAction()
{
    if (!m_showHideAction) {
        return;
    }
    const bool visible = m_window && m_window->isVisible();
    m_showHideAction->setText(visible ? tr("Hide kIRC") : tr("Show kIRC"));
}

void KircTray::updateIndicators()
{
    if (!m_item) {
        return;
    }

    const int state = m_bridge ? m_bridge->property("connection_state").toInt() : 0;
    const int unread = m_bridge ? m_bridge->property("unread_count").toInt() : 0;

    if (unread > 0) {
        m_item->setOverlayIconByPixmap(unreadBadgeIcon(unread));
        m_item->setStatus(KStatusNotifierItem::NeedsAttention);
    } else {
        // An empty icon removes the overlay again.
        m_item->setOverlayIconByPixmap(QIcon());
        m_item->setStatus(KStatusNotifierItem::Active);
    }

    QString subtitle;
    switch (state) {
    case 1:
        subtitle = tr("Connecting…");
        break;
    case 2: {
        const QString server = m_bridge->property("connected_server").toString();
        subtitle = server.isEmpty() ? tr("Connected") : tr("Connected to %1").arg(server);
        break;
    }
    default:
        subtitle = tr("Disconnected");
        break;
    }
    if (unread > 0) {
        subtitle += QStringLiteral(" — ") + tr("%n unread message(s)", "", unread);
    }
    m_item->setToolTip(QString::fromLatin1(kTrayIconName), QStringLiteral("kIRC"), subtitle);

    if (m_connectAction) {
        m_connectAction->setEnabled(state == 0);
    }
    if (m_disconnectAction) {
        m_disconnectAction->setEnabled(state != 0);
    }
}

void KircTray::onUnreadCountChanged()
{
    updateIndicators();
}

void KircTray::onStateChanged()
{
    updateIndicators();
}

void KircTray::showWindow()
{
    if (!m_window) {
        return;
    }
    m_window->show();
    m_window->raise();
    m_window->requestActivate();
    updateShowHideAction();
}

void KircTray::onShowHide()
{
    if (!m_window) {
        return;
    }
    if (m_window->isVisible()) {
        m_window->hide();
        updateShowHideAction();
    } else {
        showWindow();
    }
}

void KircTray::onConnect()
{
    if (!m_bridge || !m_config) {
        return;
    }
    showWindow();
    // Reconnect from the last saved profile.  The SASL password is never
    // persisted (see kircconfig.h), so it is intentionally passed empty — the
    // server will reject SASL and the user completes it in the form.
    const bool ok = QMetaObject::invokeMethod(m_bridge,
                                              "connect_server",
                                              Q_ARG(QString, m_config->host()),
                                              Q_ARG(int, m_config->port()),
                                              Q_ARG(bool, m_config->tls()),
                                              Q_ARG(QString, m_config->nickname()),
                                              Q_ARG(QString, m_config->saslUser()),
                                              Q_ARG(QString, QString()));
    if (!ok) {
        qWarning("kIRC: tray could not invoke IrcBridge::connect_server");
    }
}

void KircTray::onDisconnect()
{
    if (!m_bridge) {
        return;
    }
    if (!QMetaObject::invokeMethod(m_bridge, "disconnect_server")) {
        qWarning("kIRC: tray could not invoke IrcBridge::disconnect_server");
    }
}

void KircTray::onQuit()
{
    // Bypasses the QML onClosing hide-to-tray path: a real quit is a real quit.
    QCoreApplication::quit();
}