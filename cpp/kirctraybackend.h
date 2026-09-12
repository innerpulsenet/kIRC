// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Platform backend interface for KircTray.  Exactly one implementation is
// linked per build:
//   * kirctray_linux.cpp   — KStatusNotifierItem + D-Bus watcher (Linux)
//   * kirctray_windows.cpp — QSystemTrayIcon (Windows)
//
// The facade (kirctray.h/cpp) owns the context menu, the IrcBridge
// meta-object wiring and every action; the backend only presents state and
// reports interaction.  No platform headers leak through this interface.

#pragma once

#include <QObject>
#include <QString>

#include <memory>

class QMenu;
class QQuickWindow;

class KircTrayBackend : public QObject
{
    Q_OBJECT

public:
    /// The menu the facade populates (Show/Hide, Connect, Disconnect, Quit).
    /// Shown by the platform on the tray's context-menu gesture; owned by the
    /// backend.
    virtual QMenu *menu() = 0;

    /// Called after the QML engine has loaded, with the application window.
    virtual void attach(QQuickWindow *window) = 0;

    /// Present the unread badge (0 clears it) and the connection-state
    /// tooltip subtitle.  The backend composes these onto the tray icon and
    /// tooltip in whatever way the platform supports (SNI has a separate
    /// overlay icon; QSystemTrayIcon needs the badge composited into the
    /// base pixmap).
    virtual void setIndicators(int unread, const QString &tooltipSubtitle) = 0;

    /// Whether a tray host is present right now, i.e. hiding the window on
    /// close would leave the user with a way back.
    virtual bool isAvailable() const = 0;

Q_SIGNALS:
    void availabilityChanged(bool available);

    /// Primary activation (tray single/left click).  The facade toggles the
    /// window on it.  Backends must emit this at most once per physical
    /// click — in particular a double click must not toggle twice.
    void activated();
};

/// Creates the platform tray backend.
std::unique_ptr<KircTrayBackend> makeKircTrayBackend();

/// Small round counter badge, drawn in code so no icon theme asset is
/// needed.  Shared by both backends: SNI uses it as the overlay pixmap,
/// QSystemTrayIcon composites it into the base icon.  Returns a
/// transparent pixmap of `size` x `size` showing "99+" for counts > 99.
QPixmap kircUnreadBadgePixmap(int size, int unread);
