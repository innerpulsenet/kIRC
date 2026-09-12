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
//   * version 1 is the implicit value when the key is absent: the config was
//     written before the Fluent pass and may hold any pre-schema theme id.
//   * version 2 means the id was chosen (or migrated) under the Fluent pass.
//   * version 3 is dense monospace TUI palettes: the bubble/glass themes that
//     shipped under versions 1 and 2 are retired.
//   * version 4 adds the per-kind colour tokens (fgEvent, fgMessage,
//     fgPrivate, fgNotice, fgAction, fgHighlight, fgSelf) so a theme can
//     colour a notice, a private message, an action and a channel line
//     differently.  Nothing is retired by 4 — the bump exists so a config
//     stamped at an older version re-examines the new token set instead of
//     sitting on a palette that predates it.
//   load() upgrades an existing file below version 4 exactly once: any
//   *previously shipped built-in* id (`breeze`, `breeze-classic`, `oxygen`,
//   `neon`, `fluent`, `fluent-light` — everything that used to be a bubble or
//   glass theme, including a config already stamped version 2 with one of
//   them) is rewritten to the new default `tui`; a theme id that is not a
//   known old built-in (a user's own file under ~/.config/kIRC/themes/, or
//   any current built-in such as `bbs`) is left alone and only the version is
//   bumped.  The new version is persisted
//   immediately, so the migration cannot run twice; save() writes it too, so a
//   later pick always sticks.  A fresh install (no kirc.conf at all) starts at
//   the current version and nothing is written.
//
//   The version-2 quirk this fixes: phase 2 stamped version 2 *before*
//   `oxygen` joined the legacy set, so a config holding `ThemeId=oxygen` +
//   `ThemeSchemaVersion=2` could never be rewritten.  Version 3 re-examines
//   every id below it, so that config now migrates to `tui`.
//
// SECURITY — no password is ever persisted to kirc.conf:
//   kirc.conf is an ordinary world-readable plaintext INI file, so neither
//   the SASL password nor the NickServ password nor the IRC server (PASS)
//   password may be written there.
//   The SASL password lives only in memory (sessionSaslPassword, never
//   saved).  The NickServ password lives in the platform secret store
//   (see secretstore.h: KWallet on Linux, Windows Credential Manager on
//   Windows); when the store is locked or unavailable the value is kept in
//   memory for this process only and still never hits the disk.
//   The server password follows the same rule with its own secret-store
//   entry and a memory-only fallback (sessionServerPassword, used by the
//   tray to reconnect without losing the PASS line).
//
// Implemented with the plain KConfig API rather than a KConfigXT .kcfg +
// generated header: nothing here needs a settings dialog, and plain KConfig
// avoids pulling the whole KConfigCompiler/KConfigWidgets code-generation
// toolchain into the build for six keys.

#pragma once

#include <QObject>
#include <QString>

#include <memory>

namespace kirc {
class SecretStore;
}

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
    Q_PROPERTY(QString fontFamily READ fontFamily WRITE setFontFamily NOTIFY fontFamilyChanged)
    Q_PROPERTY(QString autojoin READ autojoin WRITE setAutojoin NOTIFY autojoinChanged)
    Q_PROPERTY(bool reconnect READ reconnect WRITE setReconnect NOTIFY reconnectChanged)
    Q_PROPERTY(int fontDelta READ fontDelta WRITE setFontDelta NOTIFY fontDeltaChanged)
    Q_PROPERTY(bool identifyOnConnect READ identifyOnConnect WRITE setIdentifyOnConnect NOTIFY identifyOnConnectChanged)
    Q_PROPERTY(QString nickservNick READ nickservNick WRITE setNickservNick NOTIFY nickservNickChanged)
    Q_PROPERTY(QString nickservPassword READ nickservPassword WRITE setNickservPassword NOTIFY nickservPasswordChanged)
    Q_PROPERTY(QString sessionSaslPassword READ sessionSaslPassword WRITE setSessionSaslPassword NOTIFY sessionSaslPasswordChanged)
    Q_PROPERTY(int historyLimit READ historyLimit WRITE setHistoryLimit NOTIFY historyLimitChanged)
    Q_PROPERTY(QString defaultPartReason READ defaultPartReason WRITE setDefaultPartReason NOTIFY defaultPartReasonChanged)
    Q_PROPERTY(QString serverPassword READ serverPassword WRITE setServerPassword NOTIFY serverPasswordChanged)
    Q_PROPERTY(QString sessionServerPassword READ sessionServerPassword WRITE setSessionServerPassword NOTIFY sessionServerPasswordChanged)
    Q_PROPERTY(bool respondToCtcpVersion READ respondToCtcpVersion WRITE setRespondToCtcpVersion NOTIFY respondToCtcpVersionChanged)
    Q_PROPERTY(bool glassEffects READ glassEffects WRITE setGlassEffects NOTIFY glassEffectsChanged)
    Q_PROPERTY(int glassIntensity READ glassIntensity WRITE setGlassIntensity NOTIFY glassIntensityChanged)
    Q_PROPERTY(bool glassBlur READ glassBlur WRITE setGlassBlur NOTIFY glassBlurChanged)
    Q_PROPERTY(bool glassSheen READ glassSheen WRITE setGlassSheen NOTIFY glassSheenChanged)
    Q_PROPERTY(bool glassEdges READ glassEdges WRITE setGlassEdges NOTIFY glassEdgesChanged)
    Q_PROPERTY(bool scanlines READ scanlines WRITE setScanlines NOTIFY scanlinesChanged)
    Q_PROPERTY(int scanlineAmount READ scanlineAmount WRITE setScanlineAmount NOTIFY scanlineAmountChanged)
    Q_PROPERTY(bool vignette READ vignette WRITE setVignette NOTIFY vignetteChanged)
    Q_PROPERTY(int vignetteAmount READ vignetteAmount WRITE setVignetteAmount NOTIFY vignetteAmountChanged)
    Q_PROPERTY(bool grain READ grain WRITE setGrain NOTIFY grainChanged)
    Q_PROPERTY(int grainAmount READ grainAmount WRITE setGrainAmount NOTIFY grainAmountChanged)
    Q_PROPERTY(bool flicker READ flicker WRITE setFlicker NOTIFY flickerChanged)
    Q_PROPERTY(int flickerAmount READ flickerAmount WRITE setFlickerAmount NOTIFY flickerAmountChanged)
    Q_PROPERTY(bool humBar READ humBar WRITE setHumBar NOTIFY humBarChanged)
    Q_PROPERTY(int humBarAmount READ humBarAmount WRITE setHumBarAmount NOTIFY humBarAmountChanged)
    Q_PROPERTY(bool reflection READ reflection WRITE setReflection NOTIFY reflectionChanged)
    Q_PROPERTY(int reflectionAmount READ reflectionAmount WRITE setReflectionAmount NOTIFY reflectionAmountChanged)

public:
    explicit KircConfig(QObject *parent = nullptr);

    /// Out of line (defined in kircconfig.cpp where secretstore.h is
    /// complete): the member std::unique_ptr<kirc::SecretStore> must not be
    /// destroyed with an incomplete type (MSVC instantiates the deleter in
    /// every TU that defines the implicit destructor).
    ~KircConfig() override;

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

    /// Monospace family for the terminal UI.  Empty = "let the theme decide"
    /// (the built-in themes default to Qt's "monospace" generic).
    QString fontFamily() const;
    void setFontFamily(const QString &fontFamily);

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

    /// Number of chat-history lines requested when a buffer is joined/opened
    /// (IRCv3 chathistory).  0 disables the on-join request.  Requires the
    /// server to advertise the `draft/chathistory` capability; persisted in
    /// the [UI] group like the other display/behaviour prefs.
    int historyLimit() const;
    void setHistoryLimit(int historyLimit);

    /// Reason appended to PART/QUIT when the user does not type one.  Empty
    /// means "send no reason at all".
    QString defaultPartReason() const;
    void setDefaultPartReason(const QString &defaultPartReason);

    /// IRC server password (PASS).  Like the NickServ password this is a
    /// secret and lives in KWallet (folder "kIRC", key "server-password");
    /// when the wallet is unavailable it is kept in memory only.  Never
    /// written to kirc.conf.
    QString serverPassword() const;
    void setServerPassword(const QString &serverPassword);

    /// Memory-only server password for this session (tray reconnect).  Never
    /// loaded from or saved to disk.
    QString sessionServerPassword() const;
    void setSessionServerPassword(const QString &sessionServerPassword);

    /// Whether an incoming CTCP VERSION request is answered (default on).
    /// Privacy-relevant: the reply reveals the client name and version to
    /// whoever asks, so it must be switchable off.  Pushed to the bridge via
    /// IrcBridge::set_ctcp_version_reply BEFORE connect_server.
    bool respondToCtcpVersion() const;
    void setRespondToCtcpVersion(bool respondToCtcpVersion);

    // ---- glass surfacing (in-app frosted glass over the console) ----------
    // Five [UI] keys.  These are DISPLAY preferences only: the glass colours
    // and geometry are derived at runtime in ThemeEngine from the active theme
    // (rust/qml/ThemeEngine.qml), so no theme token or theme schema changes for
    // them.  Defaults: on, intensity 60, frost/sheen/edges on.
    //
    // Frosting is in-app only — it blurs kIRC's own static underlays.  No
    // compositor/desktop blur is involved or promised.

    /// Master toggle for the frosted-glass surfacing.  Off renders the plain
    /// console, pixel-identical to the pre-glass build.
    bool glassEffects() const;
    void setGlassEffects(bool glassEffects);

    /// Strength of the glass effects, 1..100.  Clamped in the setter and on
    /// load, so a hand-edited kirc.conf cannot push it out of range.
    int glassIntensity() const;
    void setGlassIntensity(int glassIntensity);

    /// Frost (blur of the static underlay) on/off.
    bool glassBlur() const;
    void setGlassBlur(bool glassBlur);

    /// Reflection sheen on/off.
    bool glassSheen() const;
    void setGlassSheen(bool glassSheen);

    /// Lit edges + depth on/off.
    bool glassEdges() const;
    void setGlassEdges(bool glassEdges);

    // ---- CRT effects over the whole window ([UI] keys) --------------------
    // Five independent, opt-in effects that a ScanlineOverlay.qml painted above
    // every layer consumes.  They are DISPLAY preferences only: no theme token
    // and no theme-schema change is involved, so a theme switch cannot enable
    // or disable them.
    //
    // ALL FIVE DEFAULT OFF, with a subtle default intensity (scanlines 35,
    // vignette 30, grain 10, flicker 4, hum bar 8).  Unlike the glass sheet —
    // which the app has always had on — these sit OVER the message text, so
    // they are opt-in: a fresh install, and any config written before these
    // keys existed, renders exactly the pre-effects console.
    //
    // Each intensity is 1..100, clamped in the setter AND on load, so a
    // hand-edited kirc.conf cannot push it out of range.

    /// Horizontal CRT scanlines over the window.
    bool scanlines() const;
    void setScanlines(bool scanlines);

    /// Scanline strength, 1..100.
    int scanlineAmount() const;
    void setScanlineAmount(int scanlineAmount);

    /// Corner falloff (tube vignette).
    bool vignette() const;
    void setVignette(bool vignette);

    /// Vignette strength, 1..100.
    int vignetteAmount() const;
    void setVignetteAmount(int vignetteAmount);

    /// Static film/phosphor grain wash.
    bool grain() const;
    void setGrain(bool grain);

    /// Grain strength, 1..100.
    int grainAmount() const;
    void setGrainAmount(int grainAmount);

    /// Slow brightness oscillation (tube flicker).
    bool flicker() const;
    void setFlicker(bool flicker);

    /// Flicker depth, 1..100.
    int flickerAmount() const;
    void setFlickerAmount(int flickerAmount);

    /// Rolling brightness band drifting down the window.
    bool humBar() const;
    void setHumBar(bool humBar);

    /// Hum-bar strength, 1..100.
    int humBarAmount() const;
    void setHumBarAmount(int humBarAmount);

    /// Reflection: the glass family's specular gloss over the chrome (the
    /// header band and the window's top edge).  Deliberately NOT a mirrored
    /// copy of the message log — that would need a ShaderEffectSource over the
    /// scrolling ListView, the capture this codebase has paid for twice.  See
    /// rust/qml/ScanlineOverlay.qml.
    bool reflection() const;
    void setReflection(bool reflection);

    /// Reflection strength, 1..100.
    int reflectionAmount() const;
    void setReflectionAmount(int reflectionAmount);

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
    void fontFamilyChanged();
    void autojoinChanged();
    void reconnectChanged();
    void fontDeltaChanged();
    void identifyOnConnectChanged();
    void nickservNickChanged();
    void nickservPasswordChanged();
    void sessionSaslPasswordChanged();
    void historyLimitChanged();
    void defaultPartReasonChanged();
    void serverPasswordChanged();
    void sessionServerPasswordChanged();
    void respondToCtcpVersionChanged();
    void glassEffectsChanged();
    void glassIntensityChanged();
    void glassBlurChanged();
    void glassSheenChanged();
    void glassEdgesChanged();
    void scanlinesChanged();
    void scanlineAmountChanged();
    void vignetteChanged();
    void vignetteAmountChanged();
    void grainChanged();
    void grainAmountChanged();
    void flickerChanged();
    void flickerAmountChanged();
    void humBarChanged();
    void humBarAmountChanged();
    void reflectionChanged();
    void reflectionAmountChanged();

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
    QString m_themeId = QStringLiteral("tui");
    QString m_fontFamily;
    QString m_autojoin;
    bool m_reconnect = true;
    int m_fontDelta = 0;
    bool m_identifyOnConnect = false;
    QString m_nickservNick;
    QString m_nickservPassword;
    QString m_sessionSaslPassword;
    int m_historyLimit = 200; // 0 disables the on-join chathistory request
    QString m_defaultPartReason = QStringLiteral("Leaving"); // empty = send none
    QString m_serverPassword;
    QString m_sessionServerPassword;
    // Answer CTCP VERSION requests by default: the classic IRC behaviour.
    bool m_respondToCtcpVersion = true;
    // Glass surfacing ([UI] Glass* keys; see the accessor block above for the
    // policy and rust/qml/ThemeEngine.qml for the derived colours).
    bool m_glassEffects = true;
    int m_glassIntensity = 60;
    bool m_glassBlur = true;
    bool m_glassSheen = true;
    bool m_glassEdges = true;
    // CRT effects ([UI] keys; see the accessor block above).  All five are
    // opt-in and off by default with a subtle intensity, so a config that
    // predates the keys (and a fresh install) is the plain console.
    bool m_scanlines = false;
    int m_scanlineAmount = 35;
    bool m_vignette = false;
    int m_vignetteAmount = 30;
    bool m_grain = false;
    int m_grainAmount = 10;
    bool m_flicker = false;
    int m_flickerAmount = 4;
    bool m_humBar = false;
    int m_humBarAmount = 8;
    // Reflection (glass family: the specular chrome gloss).  Off by default
    // with the same opt-in rule as the CRT set.
    bool m_reflection = false;
    int m_reflectionAmount = 25;

    // Platform secret store (secretstore.h). Created once; load()/save()
    // go through it instead of touching KWallet directly.
    std::unique_ptr<kirc::SecretStore> m_secrets;
};
