// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircTray — system tray presence for kIRC.
//
// Owns a KStatusNotifierItem.  Note that in KF6 KStatusNotifierItem moved out
// of KNotifications into its own framework (KF6::StatusNotifierItem).
//
// Responsibilities:
//   * tray icon, category and tool tip;
//   * mirror IrcBridge::unread_count as an overlay ("badge") icon;
//   * a context menu with Show/Hide, Connect, Disconnect and Quit;
//   * report whether a StatusNotifierItem *host* (Plasma panel) is actually
//     present, so the QML side knows whether hiding the window on close would
//     strangle the app.
//
// Hide-to-tray itself lives in QML (main.qml onClosing), because that is where
// the window lifecycle is expressed and where the persisted setting is
// consumed; this class only supplies `available`.

#pragma once

#include <QObject>
#include <QPointer>

class QAction;
class QMenu;
class QQuickWindow;
class KStatusNotifierItem;
class KircConfig;

class KircTray : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)

public:
    explicit KircTray(KircConfig *config, QObject *parent = nullptr);
    ~KircTray() override;

    /// True when the window close may be turned into a hide, i.e. there is a
    /// StatusNotifierItem host to get the window back from.
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
    void refreshAvailability();

    KircConfig *m_config;
    QPointer<QQuickWindow> m_window;
    QPointer<QObject> m_bridge;
    KStatusNotifierItem *m_item = nullptr;
    QMenu *m_menu = nullptr;
    QAction *m_showHideAction = nullptr;
    QAction *m_connectAction = nullptr;
    QAction *m_disconnectAction = nullptr;
    QAction *m_quitAction = nullptr;
    bool m_available = false;
};