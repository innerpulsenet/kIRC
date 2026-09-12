// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Windows tray backend: QSystemTrayIcon.  Differences from SNI that this
// backend compensates for:
//   * no separate overlay-icon API — the unread badge is composited into
//     the base pixmap at every tray size;
//   * no StatusNotifierWatcher — availability is QSystemTrayIcon's own
//     isSystemTrayAvailable(), re-probed on a modest timer so an Explorer
//     restart is noticed (Phase 4 of the port tunes this);
//   * activation has no associated-window helper — the facade's
//     onShowHide() runs on the Trigger (single left click) reason only;
//     DoubleClick would toggle twice, because Trigger fires first.

#include "kirctraybackend.h"

#include <QAction>
#include <QIcon>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QQuickWindow>
#include <QSystemTrayIcon>
#include <QTimer>

namespace {

// The app artwork is embedded via kirc-windows.qrc (no icon-theme lookup on
// Windows).  Every installed size is registered so Explorer can pick a
// crisp one per DPI.
QIcon baseTrayIcon()
{
    QIcon icon;
    for (int size : {16, 22, 24, 32, 48, 64, 128, 256}) {
        icon.addFile(QStringLiteral(":/kirc/icons/%1x%1/kirc.png").arg(size));
    }
    return icon;
}

/// Composites the unread badge onto the base icon, anchored bottom-right.
QIcon compositeBadge(const QIcon &base, int unread)
{
    if (unread <= 0) {
        return base;
    }
    QIcon result;
    for (int size : {16, 22, 24, 32, 48, 64}) {
        const QPixmap basePixmap = base.pixmap(size, size);
        if (basePixmap.isNull()) {
            continue;
        }
        QPixmap canvas(size, size);
        canvas.fill(Qt::transparent);
        QPainter painter(&canvas);
        painter.drawPixmap(0, 0, basePixmap);
        const int badgeSize = qMax(10, size * 3 / 4);
        painter.drawPixmap(size - badgeSize,
                           size - badgeSize,
                           kircUnreadBadgePixmap(badgeSize, unread));
        painter.end();
        result.addPixmap(canvas);
    }
    return result;
}

class SystemTrayBackend final : public KircTrayBackend
{
    Q_OBJECT

public:
    SystemTrayBackend()
    {
        m_menu = new QMenu();
        m_tray = new QSystemTrayIcon(this);
        m_tray->setIcon(baseTrayIcon());
        m_tray->setToolTip(QStringLiteral("kIRC"));
        m_tray->setContextMenu(m_menu);

        connect(m_tray, &QSystemTrayIcon::activated,
                this, [this](QSystemTrayIcon::ActivationReason reason) {
                    if (reason == QSystemTrayIcon::Trigger) {
                        Q_EMIT activated();
                    }
                });

        m_tray->show();

        // No D-Bus watcher to tell us when the shell's tray comes and goes;
        // a cheap periodic probe catches an Explorer restart well enough
        // without burning cycles.
        m_poll = new QTimer(this);
        m_poll->setInterval(std::chrono::seconds(10));
        connect(m_poll, &QTimer::timeout, this, &SystemTrayBackend::refreshAvailability);
        m_poll->start();

        refreshAvailability();
    }

    ~SystemTrayBackend() override
    {
        // The menu is not a QWidget child of anything; drop it explicitly.
        delete m_menu;
    }

    QMenu *menu() override
    {
        return m_menu;
    }

    void attach(QQuickWindow *window) override
    {
        // Activation is routed through the facade's onShowHide(); nothing to
        // bind here.
        Q_UNUSED(window);
    }

    void setIndicators(int unread, const QString &tooltipSubtitle) override
    {
        m_tray->setIcon(compositeBadge(baseTrayIcon(), unread));
        m_tray->setToolTip(tooltipSubtitle.isEmpty()
                               ? QStringLiteral("kIRC")
                               : QStringLiteral("kIRC — ") + tooltipSubtitle);
    }

    bool isAvailable() const override
    {
        return m_available;
    }

private:
    void refreshAvailability()
    {
        const bool available = QSystemTrayIcon::isSystemTrayAvailable();
        if (m_available != available) {
            m_available = available;
            Q_EMIT availabilityChanged(available);
        }
    }

    QSystemTrayIcon *m_tray = nullptr;
    QMenu *m_menu = nullptr;
    QTimer *m_poll = nullptr;
    bool m_available = false;
};

} // namespace

std::unique_ptr<KircTrayBackend> makeKircTrayBackend()
{
    return std::make_unique<SystemTrayBackend>();
}

#include "kirctray_windows.moc"
