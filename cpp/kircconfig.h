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
// SECURITY — SASL password is deliberately NOT persisted:
//   kirc.conf is an ordinary world-readable plaintext INI file.  The SASL
//   password therefore has to be re-entered once per start.
//   NickServ identify-on-connect is stored under [Services] Password because
//   that feature is useless without it.  Prefer SASL when the server supports
//   it; move NickServ to KWallet if this file is synced.
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
    Q_PROPERTY(bool minimizeToTray READ minimizeToTray WRITE setMinimizeToTray NOTIFY minimizeToTrayChanged)
    Q_PROPERTY(QString themeId READ themeId WRITE setThemeId NOTIFY themeIdChanged)
    Q_PROPERTY(QString autojoin READ autojoin WRITE setAutojoin NOTIFY autojoinChanged)
    Q_PROPERTY(bool reconnect READ reconnect WRITE setReconnect NOTIFY reconnectChanged)
    Q_PROPERTY(int fontDelta READ fontDelta WRITE setFontDelta NOTIFY fontDeltaChanged)
    Q_PROPERTY(bool identifyOnConnect READ identifyOnConnect WRITE setIdentifyOnConnect NOTIFY identifyOnConnectChanged)
    Q_PROPERTY(QString nickservNick READ nickservNick WRITE setNickservNick NOTIFY nickservNickChanged)
    Q_PROPERTY(QString nickservPassword READ nickservPassword WRITE setNickservPassword NOTIFY nickservPasswordChanged)

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
    void minimizeToTrayChanged();
    void themeIdChanged();
    void autojoinChanged();
    void reconnectChanged();
    void fontDeltaChanged();
    void identifyOnConnectChanged();
    void nickservNickChanged();
    void nickservPasswordChanged();

private:
    // Defaults mirror the initial values in ConnectPage.qml so a first run
    // behaves exactly like the pre-persistence build.
    QString m_host = QStringLiteral("irc.libera.chat");
    int m_port = 6697;
    bool m_tls = true;
    QString m_nickname = QStringLiteral("kircuser");
    QString m_saslUser;
    bool m_minimizeToTray = true;
    QString m_themeId = QStringLiteral("breeze");
    QString m_autojoin;
    bool m_reconnect = true;
    int m_fontDelta = 0;
    bool m_identifyOnConnect = false;
    QString m_nickservNick = QStringLiteral("NickServ");
    QString m_nickservPassword;
};
