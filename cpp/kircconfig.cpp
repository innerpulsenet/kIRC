// SPDX-License-Identifier: MIT OR Apache-2.0

#include "kircconfig.h"

#include <KConfig>
#include <KConfigGroup>
#include <KWallet>

#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

namespace {

// Group/key names are part of the on-disk contract — keep them stable.
constexpr auto kConnectionGroup = "Connection";
constexpr auto kUiGroup = "UI";
constexpr auto kServicesGroup = "Services";

// KWallet location of the NickServ password.  Never written to kirc.conf.
constexpr auto kWalletFolder = "kIRC";
constexpr auto kWalletKey = "nickserv-password";

} // namespace

/// Best-effort KWallet helpers.  A null return means the wallet is locked or
/// unavailable; the caller then keeps the value in memory only for this
/// process and must not write it to disk.
namespace {

KWallet::Wallet *openKircWallet()
{
    KWallet::Wallet *wallet =
        KWallet::Wallet::openWallet(KWallet::Wallet::LocalWallet(), 0, KWallet::Wallet::Synchronous);
    if (!wallet || !wallet->isOpen()) {
        delete wallet;
        return nullptr;
    }
    if (!wallet->hasFolder(QString::fromLatin1(kWalletFolder))) {
        if (!wallet->createFolder(QString::fromLatin1(kWalletFolder))) {
            delete wallet;
            return nullptr;
        }
    }
    if (!wallet->setFolder(QString::fromLatin1(kWalletFolder))) {
        delete wallet;
        return nullptr;
    }
    return wallet;
}

bool walletReadPassword(QString *out)
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return false;
    }
    QString value;
    const int rc = wallet->readPassword(QString::fromLatin1(kWalletKey), value);
    delete wallet;
    if (rc != 0) {
        return false;
    }
    *out = value;
    return true;
}

bool walletWritePassword(const QString &value)
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return false;
    }
    const int rc = wallet->writePassword(QString::fromLatin1(kWalletKey), value);
    delete wallet;
    return rc == 0;
}

void walletRemovePassword()
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return;
    }
    if (wallet->hasEntry(QString::fromLatin1(kWalletKey))) {
        wallet->removeEntry(QString::fromLatin1(kWalletKey));
    }
    delete wallet;
}

} // namespace

KircConfig::KircConfig(QObject *parent)
    : QObject(parent)
{
}

QString KircConfig::configFilePath()
{
    // Built explicitly instead of leaning on QStandardPaths::AppConfigLocation:
    // the latter's layout depends on how organizationName/applicationName are
    // set, and the documented location (rust/qml/README.md) is a flat
    // ~/.config/kIRC/ directory.
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    return base + QStringLiteral("/kIRC/kirc.conf");
}

QString KircConfig::host() const
{
    return m_host;
}

void KircConfig::setHost(const QString &host)
{
    if (m_host == host) {
        return;
    }
    m_host = host;
    Q_EMIT hostChanged();
}

int KircConfig::port() const
{
    return m_port;
}

void KircConfig::setPort(int port)
{
    if (m_port == port) {
        return;
    }
    m_port = port;
    Q_EMIT portChanged();
}

bool KircConfig::tls() const
{
    return m_tls;
}

void KircConfig::setTls(bool tls)
{
    if (m_tls == tls) {
        return;
    }
    m_tls = tls;
    Q_EMIT tlsChanged();
}

QString KircConfig::nickname() const
{
    return m_nickname;
}

void KircConfig::setNickname(const QString &nickname)
{
    if (m_nickname == nickname) {
        return;
    }
    m_nickname = nickname;
    Q_EMIT nicknameChanged();
}

QString KircConfig::saslUser() const
{
    return m_saslUser;
}

void KircConfig::setSaslUser(const QString &saslUser)
{
    if (m_saslUser == saslUser) {
        return;
    }
    m_saslUser = saslUser;
    Q_EMIT saslUserChanged();
}

bool KircConfig::minimizeToTray() const
{
    return m_minimizeToTray;
}

void KircConfig::setMinimizeToTray(bool minimizeToTray)
{
    if (m_minimizeToTray == minimizeToTray) {
        return;
    }
    m_minimizeToTray = minimizeToTray;
    Q_EMIT minimizeToTrayChanged();
}

QString KircConfig::themeId() const
{
    return m_themeId;
}

void KircConfig::setThemeId(const QString &themeId)
{
    if (m_themeId == themeId) {
        return;
    }
    m_themeId = themeId;
    Q_EMIT themeIdChanged();
}

QString KircConfig::autojoin() const
{
    return m_autojoin;
}

void KircConfig::setAutojoin(const QString &autojoin)
{
    if (m_autojoin == autojoin) {
        return;
    }
    m_autojoin = autojoin;
    Q_EMIT autojoinChanged();
}

bool KircConfig::reconnect() const
{
    return m_reconnect;
}

void KircConfig::setReconnect(bool reconnect)
{
    if (m_reconnect == reconnect) {
        return;
    }
    m_reconnect = reconnect;
    Q_EMIT reconnectChanged();
}

int KircConfig::fontDelta() const
{
    return m_fontDelta;
}

void KircConfig::setFontDelta(int fontDelta)
{
    if (m_fontDelta == fontDelta) {
        return;
    }
    m_fontDelta = fontDelta;
    Q_EMIT fontDeltaChanged();
}

bool KircConfig::identifyOnConnect() const
{
    return m_identifyOnConnect;
}

void KircConfig::setIdentifyOnConnect(bool identifyOnConnect)
{
    if (m_identifyOnConnect == identifyOnConnect) {
        return;
    }
    m_identifyOnConnect = identifyOnConnect;
    Q_EMIT identifyOnConnectChanged();
}

QString KircConfig::nickservNick() const
{
    return m_nickservNick;
}

void KircConfig::setNickservNick(const QString &nickservNick)
{
    if (m_nickservNick == nickservNick) {
        return;
    }
    m_nickservNick = nickservNick;
    Q_EMIT nickservNickChanged();
}

QString KircConfig::nickservPassword() const
{
    return m_nickservPassword;
}

void KircConfig::setNickservPassword(const QString &nickservPassword)
{
    if (m_nickservPassword == nickservPassword) {
        return;
    }
    m_nickservPassword = nickservPassword;
    Q_EMIT nickservPasswordChanged();
}

QString KircConfig::sessionSaslPassword() const
{
    return m_sessionSaslPassword;
}

void KircConfig::setSessionSaslPassword(const QString &sessionSaslPassword)
{
    if (m_sessionSaslPassword == sessionSaslPassword) {
        return;
    }
    m_sessionSaslPassword = sessionSaslPassword;
    Q_EMIT sessionSaslPasswordChanged();
}

void KircConfig::load()
{
    const KConfig config(configFilePath(), KConfig::SimpleConfig);

    const KConfigGroup connection = config.group(QString::fromLatin1(kConnectionGroup));
    m_host = connection.readEntry(QStringLiteral("Host"), m_host);
    m_port = connection.readEntry(QStringLiteral("Port"), m_port);
    m_tls = connection.readEntry(QStringLiteral("TLS"), m_tls);
    m_nickname = connection.readEntry(QStringLiteral("Nickname"), m_nickname);
    m_saslUser = connection.readEntry(QStringLiteral("SASLUser"), m_saslUser);
    // No password key is read here (or written in save()) — see the header.

    const KConfigGroup ui = config.group(QString::fromLatin1(kUiGroup));
    m_minimizeToTray = ui.readEntry(QStringLiteral("MinimizeToTrayOnClose"), m_minimizeToTray);
    m_themeId = ui.readEntry(QStringLiteral("ThemeId"), m_themeId);
    m_autojoin = ui.readEntry(QStringLiteral("Autojoin"), m_autojoin);
    m_reconnect = ui.readEntry(QStringLiteral("Reconnect"), m_reconnect);
    m_fontDelta = ui.readEntry(QStringLiteral("FontDelta"), m_fontDelta);

    const KConfigGroup services = config.group(QString::fromLatin1(kServicesGroup));
    m_identifyOnConnect = services.readEntry(QStringLiteral("IdentifyOnConnect"), m_identifyOnConnect);
    m_nickservNick = services.readEntry(QStringLiteral("Account"), QString());
    if (m_nickservNick.isEmpty()) {
        const QString legacy = services.readEntry(QStringLiteral("NickServ"), QString());
        if (!legacy.isEmpty() && legacy.compare(QStringLiteral("NickServ"), Qt::CaseInsensitive) != 0) {
            m_nickservNick = legacy;
        }
    }
    // The password lives in KWallet, never in kirc.conf.  A legacy plaintext
    // entry is only *read* here for a one-time migration into the wallet;
    // save() deletes it from disk.
    const QString legacyPassword = services.readEntry(QStringLiteral("Password"), QString());
    m_nickservPassword.clear();
    QString walletPassword;
    if (walletReadPassword(&walletPassword)) {
        m_nickservPassword = walletPassword;
    } else if (!legacyPassword.isEmpty()) {
        m_nickservPassword = legacyPassword;
    }

    Q_EMIT hostChanged();
    Q_EMIT portChanged();
    Q_EMIT tlsChanged();
    Q_EMIT nicknameChanged();
    Q_EMIT saslUserChanged();
    Q_EMIT minimizeToTrayChanged();
    Q_EMIT themeIdChanged();
    Q_EMIT autojoinChanged();
    Q_EMIT reconnectChanged();
    Q_EMIT fontDeltaChanged();
    Q_EMIT identifyOnConnectChanged();
    Q_EMIT nickservNickChanged();
    Q_EMIT nickservPasswordChanged();
}

void KircConfig::save()
{
    const QString path = configFilePath();

    // KConfig writes the file but does not create the directory tree.
    QDir().mkpath(QFileInfo(path).absolutePath());

    KConfig config(path, KConfig::SimpleConfig);

    KConfigGroup connection = config.group(QString::fromLatin1(kConnectionGroup));
    connection.writeEntry(QStringLiteral("Host"), m_host);
    connection.writeEntry(QStringLiteral("Port"), m_port);
    connection.writeEntry(QStringLiteral("TLS"), m_tls);
    connection.writeEntry(QStringLiteral("Nickname"), m_nickname);
    connection.writeEntry(QStringLiteral("SASLUser"), m_saslUser);
    // Deliberately no password key: kirc.conf is plaintext (see header).

    KConfigGroup ui = config.group(QString::fromLatin1(kUiGroup));
    ui.writeEntry(QStringLiteral("MinimizeToTrayOnClose"), m_minimizeToTray);
    ui.writeEntry(QStringLiteral("ThemeId"), m_themeId);
    ui.writeEntry(QStringLiteral("Autojoin"), m_autojoin);
    ui.writeEntry(QStringLiteral("Reconnect"), m_reconnect);
    ui.writeEntry(QStringLiteral("FontDelta"), m_fontDelta);

    KConfigGroup services = config.group(QString::fromLatin1(kServicesGroup));
    services.writeEntry(QStringLiteral("IdentifyOnConnect"), m_identifyOnConnect);
    services.writeEntry(QStringLiteral("Account"), m_nickservNick);
    services.deleteEntry(QStringLiteral("NickServ"));
    // Never persist a password to kirc.conf: drop any legacy plaintext entry
    // and store the value in KWallet instead.  If the wallet is locked or
    // unavailable the in-memory value is kept for this process only.
    services.deleteEntry(QStringLiteral("Password"));
    if (m_nickservPassword.isEmpty()) {
        walletRemovePassword();
    } else {
        walletWritePassword(m_nickservPassword);
    }

    config.sync();
}
