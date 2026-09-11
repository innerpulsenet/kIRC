// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KircConfig — KConfig-backed persistence of the last connection profile.
//
// Stored in ~/.config/kIRC/kirc.conf, group [Connection], plus a [UI] group
// for application preferences.
//
// Exposed to QML as the context property `kircConfig` (see main.cpp), so the
// connection form can be prefilled on startup and the profile saved once a
// connection actually succeeds.
//
// THEME SCHEMA MIGRATION — the [UI] group carries an integer
// `ThemeSchemaVersion`:
//   * version 1 (the implicit value when the key is absent, i.e. every config
//     written before the Fluent pass) may hold a legacy *default* theme id.
//   * version 2 means the user's theme choice was made — or was migrated —
//     under the Fluent pass, and the stored id is authoritative.
//   load() upgrades an existing version-1 file exactly once: the legacy
//   default ids (`breeze`, `breeze-classic`) become `fluent`, every other id
//   (`oxygen`, `neon`, `fluent`, `fluent-light`, custom) is kept verbatim, and
//   the new version is persisted.  The version is bumped for non-legacy ids
//   too, so a deliberately chosen theme is never rewritten on a later start.
//   A fresh install (no kirc.conf at all) starts at the current version and
//   nothing is written.
//
// SECURITY — no password is ever persisted to kirc.conf:
//   kirc.conf is an ordinary world-readable plaintext INI file, so neither
//   the SASL password nor the NickServ password may be written there.
//   The SASL password lives only in memory (sessionSaslPassword, never
//   saved).  The NickServ password lives in KWallet (folder "kIRC", key
//   "nickserv-password"); when the wallet is locked or unavailable the value
//   is kept in memory for this process only and still never hits the disk.
//
// Implemented with the plain KConfig API rather than a KConfigXT .kcfg +
// generated header: nothing here needs a settings dialog, and plain KConfig
// avoids pulling the whole KConfigCompiler/KConfigWidgets code-generation
// toolchain into the build for six keys.

#pragma once

#include <QObject>
#include <QString>

class KircConfig : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString host READ host WRITE setHost NOTIFY hostChanged)
    Q_PROPERTY(int port READ port WRITE setPort NOTIFY portChanged)
    Q_PROPERTY(bool tls READ tls WRITE setTls NOTIFY tlsChanged)
    Q_PROPERTY(QString nickname READ nickname WRITE setNickname NOTIFY nicknameChanged)
    Q_PROPERTY(QString saslUser READ saslUser WRITE setSaslUser NOTIFY saslUserChanged)
    Q_PROPERTY(int windowWidth READ windowWidth WRITE setWindowWidth NOTIFY windowWidthChanged)
    Q_PROPERTY(int windowHeight READ windowHeight WRITE setWindowHeight NOTIFY windowHeightChanged)
    Q_PROPERTY(int saslMechanism READ saslMechanism WRITE setSaslMechanism NOTIFY saslMechanismChanged)
    Q_PROPERTY(bool notifyHighlights READ notifyHighlights WRITE setNotifyHighlights NOTIFY notifyHighlightsChanged)
    Q_PROPERTY(bool notifyDirectMessages READ notifyDirectMessages WRITE setNotifyDirectMessages NOTIFY notifyDirectMessagesChanged)
    Q_PROPERTY(int reconnectLimit READ reconnectLimit WRITE setReconnectLimit NOTIFY reconnectLimitChanged)
    Q_PROPERTY(bool reconnectAfterAuthFailure READ reconnectAfterAuthFailure WRITE setReconnectAfterAuthFailure NOTIFY reconnectAfterAuthFailureChanged)
    Q_PROPERTY(bool minimizeToTray READ minimizeToTray WRITE setMinimizeToTray NOTIFY minimizeToTrayChanged)
    Q_PROPERTY(bool showTimestamps READ showTimestamps WRITE setShowTimestamps NOTIFY showTimestampsChanged)
    Q_PROPERTY(QString themeId READ themeId WRITE setThemeId NOTIFY themeIdChanged)
    Q_PROPERTY(QString autojoin READ autojoin WRITE setAutojoin NOTIFY autojoinChanged)
    Q_PROPERTY(bool reconnect READ reconnect WRITE setReconnect NOTIFY reconnectChanged)
    Q_PROPERTY(int fontDelta READ fontDelta WRITE setFontDelta NOTIFY fontDeltaChanged)
    Q_PROPERTY(bool identifyOnConnect READ identifyOnConnect WRITE setIdentifyOnConnect NOTIFY identifyOnConnectChanged)
    Q_PROPERTY(QString nickservNick READ nickservNick WRITE setNickservNick NOTIFY nickservNickChanged)
    Q_PROPERTY(QString nickservPassword READ nickservPassword WRITE setNickservPassword NOTIFY nickservPasswordChanged)
    Q_PROPERTY(QString sessionSaslPassword READ sessionSaslPassword WRITE setSessionSaslPassword NOTIFY sessionSaslPasswordChanged)

public:
    explicit KircConfig(QObject *parent = nullptr);

    /// Absolute path of the config file (~/.config/kIRC/kirc.conf by
    /// convention).  Kept public so callers/logs can name the file without
    /// duplicating the layout rules.
    static QString configFilePath();

    QString host() const;
    void setHost(const QString &host);

    int port() const;
    void setPort(int port);

    bool tls() const;
    void setTls(bool tls);

    QString nickname() const;
    void setNickname(const QString &nickname);

    QString saslUser() const;
    void setSaslUser(const QString &saslUser);

    int windowWidth() const;
    void setWindowWidth(int windowWidth);

    int windowHeight() const;
    void setWindowHeight(int windowHeight);

    /// SASL mechanism: 0 = auto, 1 = PLAIN, 2 = EXTERNAL.  Kept in sync with
    /// IrcBridge::set_sasl_mechanism.  (SCRAM-SHA-256-only is "Auto".)
    int saslMechanism() const;
    void setSaslMechanism(int saslMechanism);

    bool notifyHighlights() const;
    void setNotifyHighlights(bool notifyHighlights);

    bool notifyDirectMessages() const;
    void setNotifyDirectMessages(bool notifyDirectMessages);

    /// Max automatic reconnect attempts after a drop (0 = unlimited).
    int reconnectLimit() const;
    void setReconnectLimit(int reconnectLimit);

    /// Whether a drop that looks like an authentication failure may be
    /// retried.  Off by default so a bad password cannot SASL-904-loop.
    bool reconnectAfterAuthFailure() const;
    void setReconnectAfterAuthFailure(bool reconnectAfterAuthFailure);

    bool showTimestamps() const;
    void setShowTimestamps(bool showTimestamps);

    bool minimizeToTray() const;
    void setMinimizeToTray(bool minimizeToTray);

    QString themeId() const;
    void setThemeId(const QString &themeId);

    QString autojoin() const;
    void setAutojoin(const QString &autojoin);

    bool reconnect() const;
    void setReconnect(bool reconnect);

    int fontDelta() const;
    void setFontDelta(int fontDelta);

    bool identifyOnConnect() const;
    void setIdentifyOnConnect(bool identifyOnConnect);

    QString nickservNick() const;
    void setNickservNick(const QString &nickservNick);

    QString nickservPassword() const;
    void setNickservPassword(const QString &nickservPassword);

    /// Memory-only SASL password for this session (tray reconnect).  Never
    /// loaded from or saved to disk.
    QString sessionSaslPassword() const;
    void setSessionSaslPassword(const QString &sessionSaslPassword);

    /// Re-read every value from disk.  Called once at startup, before the QML
    /// engine is created, so the form is prefilled on first paint.
    void load();

public Q_SLOTS:
    /// Write the current values back to disk.  Never writes a password.
    void save();

Q_SIGNALS:
    void hostChanged();
    void portChanged();
    void tlsChanged();
    void nicknameChanged();
    void saslUserChanged();
    void windowWidthChanged();
    void windowHeightChanged();
    void saslMechanismChanged();
    void notifyHighlightsChanged();
    void notifyDirectMessagesChanged();
    void reconnectLimitChanged();
    void reconnectAfterAuthFailureChanged();
    void showTimestampsChanged();
    void minimizeToTrayChanged();
    void themeIdChanged();
    void autojoinChanged();
    void reconnectChanged();
    void fontDeltaChanged();
    void identifyOnConnectChanged();
    void nickservNickChanged();
    void nickservPasswordChanged();
    void sessionSaslPasswordChanged();

private:
    // Defaults mirror the initial values in ConnectPage.qml so a first run
    // behaves exactly like the pre-persistence build.
    QString m_host = QStringLiteral("irc.libera.chat");
    int m_port = 6697;
    bool m_tls = true;
    QString m_nickname = QStringLiteral("kircuser");
    QString m_saslUser;
    int m_windowWidth = 1024;
    int m_windowHeight = 700;
    int m_saslMechanism = 0; // 0 = auto, 1 = PLAIN, 2 = EXTERNAL
    bool m_notifyHighlights = true;
    bool m_notifyDirectMessages = true;
    int m_reconnectLimit = 10; // 0 = unlimited
    bool m_reconnectAfterAuthFailure = false;
    bool m_showTimestamps = true;
    bool m_minimizeToTray = true;
    QString m_themeId = QStringLiteral("fluent");
    QString m_autojoin;
    bool m_reconnect = true;
    int m_fontDelta = 0;
    bool m_identifyOnConnect = false;
    QString m_nickservNick;
    QString m_nickservPassword;
    QString m_sessionSaslPassword;
};
