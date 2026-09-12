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

// KWallet location of the secrets.  Never written to kirc.conf.
constexpr auto kWalletFolder = "kIRC";
constexpr auto kWalletKeyNickserv = "nickserv-password";
constexpr auto kWalletKeyServer = "server-password";

// Version of the [UI] theme-selection schema (see the header for the policy).
// Version 1 is what every config written before the Fluent pass implies;
// version 3 is the current schema — dense monospace TUI palettes.  The current
// version is written back by load()'s one-time migration and by every save(),
// so a later theme pick always sticks.
constexpr int kThemeSchemaVersion = 3;
constexpr int kThemeSchemaVersionLegacy = 1;

// Built-in theme ids that shipped before the terminal reskin (schema < 3):
// everything that used to be a bubble or glass theme.  A stored id from this
// list is indistinguishable from "never chose" (it is either the old default
// or a stock id the redesign replaced), so the migration rewrites it to the
// new default.  Ids outside this list — including a user's own theme file —
// are deliberate choices and are left alone.
constexpr auto kNewDefaultThemeId = "tui";
constexpr auto kRetiredBuiltinThemeIds = {
    "breeze",
    "breeze-classic",
    "oxygen",
    "neon",
    "fluent",
    "fluent-light",
};

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

bool walletReadPassword(const QString &key, QString *out)
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return false;
    }
    QString value;
    const int rc = wallet->readPassword(key, value);
    delete wallet;
    if (rc != 0) {
        return false;
    }
    *out = value;
    return true;
}

bool walletWritePassword(const QString &key, const QString &value)
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return false;
    }
    const int rc = wallet->writePassword(key, value);
    delete wallet;
    return rc == 0;
}

void walletRemovePassword(const QString &key)
{
    KWallet::Wallet *wallet = openKircWallet();
    if (!wallet) {
        return;
    }
    if (wallet->hasEntry(key)) {
        wallet->removeEntry(key);
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

bool KircConfig::showTimestamps() const
{
    return m_showTimestamps;
}

void KircConfig::setShowTimestamps(bool showTimestamps)
{
    if (m_showTimestamps == showTimestamps) {
        return;
    }
    m_showTimestamps = showTimestamps;
    Q_EMIT showTimestampsChanged();
}

int KircConfig::windowWidth() const
{
    return m_windowWidth;
}

void KircConfig::setWindowWidth(int windowWidth)
{
    if (m_windowWidth == windowWidth) {
        return;
    }
    m_windowWidth = windowWidth;
    Q_EMIT windowWidthChanged();
}

int KircConfig::windowHeight() const
{
    return m_windowHeight;
}

void KircConfig::setWindowHeight(int windowHeight)
{
    if (m_windowHeight == windowHeight) {
        return;
    }
    m_windowHeight = windowHeight;
    Q_EMIT windowHeightChanged();
}

int KircConfig::saslMechanism() const
{
    return m_saslMechanism;
}

void KircConfig::setSaslMechanism(int saslMechanism)
{
    if (saslMechanism < 0 || saslMechanism > 2) {
        return;
    }
    if (m_saslMechanism == saslMechanism) {
        return;
    }
    m_saslMechanism = saslMechanism;
    Q_EMIT saslMechanismChanged();
}

bool KircConfig::notifyHighlights() const
{
    return m_notifyHighlights;
}

void KircConfig::setNotifyHighlights(bool notifyHighlights)
{
    if (m_notifyHighlights == notifyHighlights) {
        return;
    }
    m_notifyHighlights = notifyHighlights;
    Q_EMIT notifyHighlightsChanged();
}

bool KircConfig::notifyDirectMessages() const
{
    return m_notifyDirectMessages;
}

void KircConfig::setNotifyDirectMessages(bool notifyDirectMessages)
{
    if (m_notifyDirectMessages == notifyDirectMessages) {
        return;
    }
    m_notifyDirectMessages = notifyDirectMessages;
    Q_EMIT notifyDirectMessagesChanged();
}

int KircConfig::reconnectLimit() const
{
    return m_reconnectLimit;
}

void KircConfig::setReconnectLimit(int reconnectLimit)
{
    if (reconnectLimit < 0) {
        reconnectLimit = 0;
    }
    if (m_reconnectLimit == reconnectLimit) {
        return;
    }
    m_reconnectLimit = reconnectLimit;
    Q_EMIT reconnectLimitChanged();
}

bool KircConfig::reconnectAfterAuthFailure() const
{
    return m_reconnectAfterAuthFailure;
}

void KircConfig::setReconnectAfterAuthFailure(bool reconnectAfterAuthFailure)
{
    if (m_reconnectAfterAuthFailure == reconnectAfterAuthFailure) {
        return;
    }
    m_reconnectAfterAuthFailure = reconnectAfterAuthFailure;
    Q_EMIT reconnectAfterAuthFailureChanged();
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

QString KircConfig::fontFamily() const
{
    return m_fontFamily;
}

void KircConfig::setFontFamily(const QString &fontFamily)
{
    if (m_fontFamily == fontFamily) {
        return;
    }
    m_fontFamily = fontFamily;
    Q_EMIT fontFamilyChanged();
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

int KircConfig::historyLimit() const
{
    return m_historyLimit;
}

void KircConfig::setHistoryLimit(int historyLimit)
{
    if (historyLimit < 0) {
        historyLimit = 0;
    }
    if (m_historyLimit == historyLimit) {
        return;
    }
    m_historyLimit = historyLimit;
    Q_EMIT historyLimitChanged();
}

QString KircConfig::defaultPartReason() const
{
    return m_defaultPartReason;
}

void KircConfig::setDefaultPartReason(const QString &defaultPartReason)
{
    if (m_defaultPartReason == defaultPartReason) {
        return;
    }
    m_defaultPartReason = defaultPartReason;
    Q_EMIT defaultPartReasonChanged();
}

QString KircConfig::serverPassword() const
{
    return m_serverPassword;
}

void KircConfig::setServerPassword(const QString &serverPassword)
{
    if (m_serverPassword == serverPassword) {
        return;
    }
    m_serverPassword = serverPassword;
    Q_EMIT serverPasswordChanged();
}

QString KircConfig::sessionServerPassword() const
{
    return m_sessionServerPassword;
}

void KircConfig::setSessionServerPassword(const QString &sessionServerPassword)
{
    if (m_sessionServerPassword == sessionServerPassword) {
        return;
    }
    m_sessionServerPassword = sessionServerPassword;
    Q_EMIT sessionServerPasswordChanged();
}

bool KircConfig::respondToCtcpVersion() const
{
    return m_respondToCtcpVersion;
}

void KircConfig::setRespondToCtcpVersion(bool respondToCtcpVersion)
{
    if (m_respondToCtcpVersion == respondToCtcpVersion) {
        return;
    }
    m_respondToCtcpVersion = respondToCtcpVersion;
    Q_EMIT respondToCtcpVersionChanged();
}

void KircConfig::load()
{
    KConfig config(configFilePath(), KConfig::SimpleConfig);

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
    m_fontFamily = ui.readEntry(QStringLiteral("FontFamily"), m_fontFamily);
    m_autojoin = ui.readEntry(QStringLiteral("Autojoin"), m_autojoin);
    m_reconnect = ui.readEntry(QStringLiteral("Reconnect"), m_reconnect);
    m_fontDelta = ui.readEntry(QStringLiteral("FontDelta"), m_fontDelta);
    m_windowWidth = ui.readEntry(QStringLiteral("WindowWidth"), m_windowWidth);
    m_windowHeight = ui.readEntry(QStringLiteral("WindowHeight"), m_windowHeight);
    m_saslMechanism = ui.readEntry(QStringLiteral("SaslMechanism"), m_saslMechanism);
    if (m_saslMechanism < 0 || m_saslMechanism > 2) {
        m_saslMechanism = 0;
    }
    m_notifyHighlights = ui.readEntry(QStringLiteral("NotifyHighlights"), m_notifyHighlights);
    m_notifyDirectMessages = ui.readEntry(QStringLiteral("NotifyDirectMessages"), m_notifyDirectMessages);
    m_reconnectLimit = ui.readEntry(QStringLiteral("ReconnectLimit"), m_reconnectLimit);
    if (m_reconnectLimit < 0) {
        m_reconnectLimit = 0;
    }
    m_reconnectAfterAuthFailure =
        ui.readEntry(QStringLiteral("ReconnectAfterAuthFailure"), m_reconnectAfterAuthFailure);
    m_showTimestamps = ui.readEntry(QStringLiteral("ShowTimestamps"), m_showTimestamps);
    m_historyLimit = ui.readEntry(QStringLiteral("HistoryLimit"), m_historyLimit);
    if (m_historyLimit < 0) {
        m_historyLimit = 200;
    }
    m_defaultPartReason = ui.readEntry(QStringLiteral("DefaultPartReason"), m_defaultPartReason);
    m_respondToCtcpVersion =
        ui.readEntry(QStringLiteral("RespondToCtcpVersion"), m_respondToCtcpVersion);

    // ---- one-time theme-schema migration (< 3 -> 3; policy in the header) --
    // A config file that predates the key is version 1 by definition; a fresh
    // install (no file at all) is born at the current version and has nothing
    // to migrate.  QFileInfo::exists() is checked *before* reading, because
    // KConfig would happily report the default for a file that is not there.
    const int storedThemeSchema = QFileInfo::exists(configFilePath())
        ? ui.readEntry(QStringLiteral("ThemeSchemaVersion"), kThemeSchemaVersionLegacy)
        : kThemeSchemaVersion;
    if (storedThemeSchema < kThemeSchemaVersion) {
        // Only *previously shipped built-ins* migrate (breeze, breeze-classic,
        // oxygen, neon, fluent, fluent-light): they are either the old default
        // or one of the stock bubble/glass themes the terminal reskin
        // replaced.  This deliberately re-examines configs already stamped
        // version 2 — phase 2 stamped 2 before `oxygen` joined its legacy set,
        // so a `ThemeId=oxygen` config could never have been rewritten.  Any
        // other id (a user's own theme under ~/.config/kIRC/themes/) is a
        // deliberate choice and is left untouched.  The version is persisted
        // either way, so this runs exactly once — a later pick writes the
        // version too and therefore sticks.
        bool retired = false;
        for (const char *candidate : kRetiredBuiltinThemeIds) {
            if (m_themeId.compare(QString::fromLatin1(candidate), Qt::CaseInsensitive) == 0) {
                retired = true;
                break;
            }
        }
        KConfigGroup uiWrite = config.group(QString::fromLatin1(kUiGroup));
        if (retired) {
            m_themeId = QString::fromLatin1(kNewDefaultThemeId);
            uiWrite.writeEntry(QStringLiteral("ThemeId"), m_themeId);
        }
        uiWrite.writeEntry(QStringLiteral("ThemeSchemaVersion"), kThemeSchemaVersion);
        config.sync();
    }

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
    if (walletReadPassword(QString::fromLatin1(kWalletKeyNickserv), &walletPassword)) {
        m_nickservPassword = walletPassword;
    } else if (!legacyPassword.isEmpty()) {
        m_nickservPassword = legacyPassword;
    }
    // The IRC server password (PASS) is a secret too: KWallet only, no
    // plaintext fallback (there was never a legacy kirc.conf key for it).
    m_serverPassword.clear();
    QString walletServerPassword;
    if (walletReadPassword(QString::fromLatin1(kWalletKeyServer), &walletServerPassword)) {
        m_serverPassword = walletServerPassword;
    }

    Q_EMIT hostChanged();
    Q_EMIT portChanged();
    Q_EMIT tlsChanged();
    Q_EMIT nicknameChanged();
    Q_EMIT saslUserChanged();
    Q_EMIT windowWidthChanged();
    Q_EMIT windowHeightChanged();
    Q_EMIT saslMechanismChanged();
    Q_EMIT notifyHighlightsChanged();
    Q_EMIT notifyDirectMessagesChanged();
    Q_EMIT reconnectLimitChanged();
    Q_EMIT reconnectAfterAuthFailureChanged();
    Q_EMIT showTimestampsChanged();
    Q_EMIT minimizeToTrayChanged();
    Q_EMIT themeIdChanged();
    Q_EMIT fontFamilyChanged();
    Q_EMIT autojoinChanged();
    Q_EMIT reconnectChanged();
    Q_EMIT fontDeltaChanged();
    Q_EMIT identifyOnConnectChanged();
    Q_EMIT nickservNickChanged();
    Q_EMIT nickservPasswordChanged();
    Q_EMIT historyLimitChanged();
    Q_EMIT defaultPartReasonChanged();
    Q_EMIT serverPasswordChanged();
    Q_EMIT respondToCtcpVersionChanged();
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
    ui.writeEntry(QStringLiteral("FontFamily"), m_fontFamily);
    // A theme picked (or migrated) by this build is a v3 choice; writing the
    // version here is what makes a later pick stick across restarts.
    ui.writeEntry(QStringLiteral("ThemeSchemaVersion"), kThemeSchemaVersion);
    ui.writeEntry(QStringLiteral("Autojoin"), m_autojoin);
    ui.writeEntry(QStringLiteral("Reconnect"), m_reconnect);
    ui.writeEntry(QStringLiteral("FontDelta"), m_fontDelta);
    ui.writeEntry(QStringLiteral("WindowWidth"), m_windowWidth);
    ui.writeEntry(QStringLiteral("WindowHeight"), m_windowHeight);
    ui.writeEntry(QStringLiteral("SaslMechanism"), m_saslMechanism);
    ui.writeEntry(QStringLiteral("NotifyHighlights"), m_notifyHighlights);
    ui.writeEntry(QStringLiteral("NotifyDirectMessages"), m_notifyDirectMessages);
    ui.writeEntry(QStringLiteral("ReconnectLimit"), m_reconnectLimit);
    ui.writeEntry(QStringLiteral("ReconnectAfterAuthFailure"), m_reconnectAfterAuthFailure);
    ui.writeEntry(QStringLiteral("ShowTimestamps"), m_showTimestamps);
    ui.writeEntry(QStringLiteral("HistoryLimit"), m_historyLimit);
    ui.writeEntry(QStringLiteral("DefaultPartReason"), m_defaultPartReason);
    ui.writeEntry(QStringLiteral("RespondToCtcpVersion"), m_respondToCtcpVersion);

    KConfigGroup services = config.group(QString::fromLatin1(kServicesGroup));
    services.writeEntry(QStringLiteral("IdentifyOnConnect"), m_identifyOnConnect);
    services.writeEntry(QStringLiteral("Account"), m_nickservNick);
    services.deleteEntry(QStringLiteral("NickServ"));
    // Never persist a password to kirc.conf: drop any legacy plaintext entry
    // and store the value in KWallet instead.  If the wallet is locked or
    // unavailable the in-memory value is kept for this process only.
    services.deleteEntry(QStringLiteral("Password"));
    if (m_nickservPassword.isEmpty()) {
        walletRemovePassword(QString::fromLatin1(kWalletKeyNickserv));
    } else {
        walletWritePassword(QString::fromLatin1(kWalletKeyNickserv), m_nickservPassword);
    }
    // Same rule for the IRC server password: KWallet only, never kirc.conf.
    if (m_serverPassword.isEmpty()) {
        walletRemovePassword(QString::fromLatin1(kWalletKeyServer));
    } else {
        walletWritePassword(QString::fromLatin1(kWalletKeyServer), m_serverPassword);
    }

    config.sync();
}
