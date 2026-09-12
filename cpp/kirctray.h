// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircTray — system tray facade for kIRC.
//
// Owns the context menu, the IrcBridge meta-object wiring and the shared
// connect/disconnect action policy.  Platform presentation (StatusNotifierItem
// on Linux, QSystemTrayIcon on Windows) lives in the backend selected by
// makeKircTrayBackend() — see kirctraybackend.h.
//
// Responsibilities:
//   * tray icon, badge and tool tip via the backend;
//   * mirror IrcBridge::unread_count as an overlay ("badge") icon;
//   * a context menu with Show/Hide, Connect, Disconnect and Quit;
//   * report whether a tray host is actually present, so the QML side knows
//     whether hiding the window on close would strangle the app.
//
// Hide-to-tray itself lives in QML (main.qml onClosing), because that is where
// the window lifecycle is expressed and where the persisted setting is
// consumed; this class only supplies `available`.

#pragma once

#include <QObject>
#include <QPointer>
#include <QString>

#include <memory>

class QAction;
class QMenu;
class QQuickWindow;
class KircConfig;
class KircTrayBackend;

class KircTray : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)

public:
    explicit KircTray(KircConfig *config, QObject *parent = nullptr);
    ~KircTray() override;

    /// True when the window close may be turned into a hide, i.e. there is a
    /// tray host to get the window back from.
    bool isAvailable() const;

    /// Second half of construction: wires up the window and the IrcBridge,
    /// both of which only exist after the QML engine has loaded.
    void attach(QQuickWindow *window, QObject *bridge);

    void showWindow();

Q_SIGNALS:
    void availableChanged();

public Q_SLOTS:
    void onUnreadCountChanged();
    void onStateChanged();
    void onShowHide();
    void onConnect();
    void onDisconnect();
    void onQuit();

private:
    void updateIndicators();
    void updateShowHideAction();
    void setAvailable(bool available);

    KircConfig *m_config;
    QPointer<QQuickWindow> m_window;
    QPointer<QObject> m_bridge;
    std::unique_ptr<KircTrayBackend> m_backend;
    QMenu *m_menu = nullptr;
    QAction *m_showHideAction = nullptr;
    QAction *m_connectAction = nullptr;
    QAction *m_disconnectAction = nullptr;
    QAction *m_quitAction = nullptr;
    bool m_available = false;
};
