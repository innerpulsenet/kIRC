// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircTray facade — everything that is shared between the Linux
// (StatusNotifierItem) and Windows (QSystemTrayIcon) tray backends:
// the context menu and its actions, the IrcBridge meta-object wiring, the
// tray connect policy (which must match the UI's), availability state and
// the drawn unread badge.  Platform presentation lives in
// kirctray_linux.cpp / kirctray_windows.cpp.

#include "kirctray.h"
#include "kirctraybackend.h"

#include "kircconfig.h"

#include <QAction>
#include <QColor>
#include <QCoreApplication>
#include <QFont>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QQuickWindow>
#include <QVariant>

QPixmap kircUnreadBadgePixmap(int size, int unread)
{
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
    // Scale the original 22px metrics (22-9 for two digits, 22-6 for one).
    font.setPixelSize(qMax(6, size - (unread > 9 ? size * 9 / 22 : size * 6 / 22)));
    painter.setFont(font);
    painter.setPen(Qt::white);
    painter.drawText(pixmap.rect(), Qt::AlignCenter,
                     unread > 99 ? QStringLiteral("99+") : QString::number(unread));
    painter.end();

    return pixmap;
}

KircTray::KircTray(KircConfig *config, QObject *parent)
    : QObject(parent)
    , m_config(config)
{
    // We provide the whole menu ourselves (Show/Hide, Connect, Disconnect,
    // Quit) because a stock "Quit" action cannot implement hide-to-tray.
    // The menu widget belongs to the backend (SNI hands out its own).
    m_backend = makeKircTrayBackend();
    connect(m_backend.get(), &KircTrayBackend::availabilityChanged,
            this, &KircTray::setAvailable);
    connect(m_backend.get(), &KircTrayBackend::activated, this, &KircTray::onShowHide);

    m_menu = m_backend->menu();
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

    setAvailable(m_backend->isAvailable());
}

KircTray::~KircTray() = default;

bool KircTray::isAvailable() const
{
    return m_available;
}

void KircTray::setAvailable(bool available)
{
    if (m_available == available) {
        return;
    }
    m_available = available;
    qInfo("kIRC: tray host %s", available ? "available" : "not available");
    Q_EMIT availableChanged();
}

void KircTray::attach(QQuickWindow *window, QObject *bridge)
{
    m_window = window;
    m_bridge = bridge;

    if (m_backend && m_window) {
        m_backend->attach(m_window);
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
    if (!m_backend) {
        return;
    }

    const int state = m_bridge ? m_bridge->property("connection_state").toInt() : 0;
    const int unread = m_bridge ? m_bridge->property("unread_count").toInt() : 0;

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

    m_backend->setIndicators(unread, subtitle);

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
    // Mechanism must be selected BEFORE connect_server (bridge contract):
    // 0 = auto, 1 = PLAIN, 2 = EXTERNAL.  invokeMethod returns false when
    // the bridge predates set_sasl_mechanism; connect must still proceed.
    if (!QMetaObject::invokeMethod(m_bridge,
                                   "set_sasl_mechanism",
                                   Q_ARG(int, m_config->saslMechanism()))) {
        qWarning("kIRC: tray could not invoke IrcBridge::set_sasl_mechanism");
    }
    // IRC PASS, if one is configured.  Prefer the value entered this session
    // (memory-only), then the secret-store-backed one — same pattern as the
    // SASL password below.  Also must be set BEFORE connect_server; a bridge
    // without the invokable is tolerated (connect proceeds without PASS).
    const QString serverPassword = m_config->sessionServerPassword().isEmpty()
        ? m_config->serverPassword()
        : m_config->sessionServerPassword();
    if (!serverPassword.isEmpty() && !QMetaObject::invokeMethod(m_bridge,
                                                                "set_server_password",
                                                                Q_ARG(QString, serverPassword))) {
        qWarning("kIRC: tray could not invoke IrcBridge::set_server_password");
    }
    // CTCP VERSION auto-reply preference, also BEFORE connect_server (same
    // contract as set_sasl_mechanism).  A tray reconnect must carry the
    // persisted choice, or a user who turned the reply off would silently
    // start advertising the client again after a drop.  A bridge without the
    // invokable is tolerated (it keeps its own default).
    if (!QMetaObject::invokeMethod(m_bridge,
                                   "set_ctcp_version_reply",
                                   Q_ARG(bool, m_config->respondToCtcpVersion()))) {
        qWarning("kIRC: tray could not invoke IrcBridge::set_ctcp_version_reply");
    }
    // Reconnect from the last saved profile.  The SASL password is memory-only
    // (KircConfig::sessionSaslPassword, never on disk): empty unless the user
    // connected with SASL this session, in which case reuse it so the tray
    // reconnect does not SASL-904-loop.
    const bool ok = QMetaObject::invokeMethod(m_bridge,
                                              "connect_server",
                                              Q_ARG(QString, m_config->host()),
                                              Q_ARG(int, m_config->port()),
                                              Q_ARG(bool, m_config->tls()),
                                              Q_ARG(QString, m_config->nickname()),
                                              Q_ARG(QString, m_config->saslUser()),
                                              Q_ARG(QString, m_config->sessionSaslPassword()));
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
