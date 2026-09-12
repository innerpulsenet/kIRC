// SPDX-License-Identifier: MIT OR Apache-2.0
//
// tst_config_secrets.cpp — KircConfig's secret-persistence contract (the
// C++ half of the phase-3 "honest secrets" rules).
//
// Proves, with a scripted FakeSecretStore (never a platform backend, so the
// test builds identically everywhere and touches no real credentials):
//
//   * save() with no secret change makes ZERO store calls — a save triggered
//     by window geometry or an effect toggle must not rewrite credentials
//     (the regression this guards),
//   * a changed NickServ password is written exactly once, a cleared one is
//     removed, and neither happens again on a follow-up save(),
//   * a failed write keeps the value dirty in memory (the next save()
//     retries), keeps the value out of kirc.conf, and surfaces one
//     plain-text sentence through secretsStatus — naming the backend, never
//     the secret value,
//   * the legacy [Services] Password plaintext fallback migrates into the
//     store on the next save() and disappears from kirc.conf,
//   * every persisted kirc.conf key still round-trips save()/load()
//     unchanged, including the effect-intensity clamps.
//
// Usage: tst_config_secrets  (no environment needed; each test gets its own
// QTemporaryDir, so the user's real kirc.conf is never touched).

#include <QtTest>

#include <QFile>
#include <QTemporaryDir>

#include <memory>

#include "kircconfig.h"
#include "secretstore.h"

namespace {

/// Scriptable in-memory SecretStore double: every call is recorded for the
/// assertions below, and the test chooses the result of the next
/// read/write/remove up front (defaults: nothing stored, everything Ok).
class FakeSecretStore final : public kirc::SecretStore
{
public:
    struct Call {
        QString op;            // "read" / "write" / "remove"
        int secret = -1;       // static_cast<int>(kirc::Secret::...)
        QString value;         // write payload
    };

    kirc::SecretReadResult readResult = kirc::SecretReadResult::NotFound;
    kirc::SecretWriteResult writeResult = kirc::SecretWriteResult::Ok;
    kirc::SecretWriteResult removeResult = kirc::SecretWriteResult::Ok;
    QString storedValue;       // handed out when readResult == Found
    QList<Call> calls;

    kirc::SecretReadResult read(kirc::Secret secret, QString *value) override
    {
        calls.append({QStringLiteral("read"), static_cast<int>(secret), QString()});
        if (readResult == kirc::SecretReadResult::Found) {
            *value = storedValue;
        }
        return readResult;
    }

    kirc::SecretWriteResult write(kirc::Secret secret, const QString &value) override
    {
        calls.append({QStringLiteral("write"), static_cast<int>(secret), value});
        return writeResult;
    }

    kirc::SecretWriteResult remove(kirc::Secret secret) override
    {
        calls.append({QStringLiteral("remove"), static_cast<int>(secret), QString()});
        return removeResult;
    }

    QString backendName() const override
    {
        return QStringLiteral("TestVault");
    }
};

QString readFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll());
}

void writeFile(const QString &path, const QString &content)
{
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate));
    file.write(content.toUtf8());
}

/// A KircConfig pointed at `path` with the fake store injected (the test
/// keeps the raw pointer for scripting; the config owns the store).
std::unique_ptr<KircConfig> makeConfig(const QString &path, FakeSecretStore **storeOut)
{
    auto store = std::make_unique<FakeSecretStore>();
    *storeOut = store.get();
    return std::make_unique<KircConfig>(path, std::move(store));
}

} // namespace

// The platform makeSecretStore() is deliberately not linked into this test
// (no KWallet / Credential Manager code here).  The default KircConfig
// constructor still references it, so a stub definition keeps the link
// honest; every test constructs KircConfig through the injecting
// constructor and this stub is never called.
namespace kirc {
std::unique_ptr<SecretStore> makeSecretStore()
{
    return nullptr;
}
} // namespace kirc

class TstConfigSecrets : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void saveWithoutSecretChangesTouchesTheStoreZeroTimes();
    void changedNickservPasswordIsWrittenExactlyOnce();
    void clearedNickservPasswordIsRemoved();
    void unavailableWriteKeepsValueDirtyAndReportsStatus();
    void legacyPlaintextPasswordMigratesIntoTheStore();
    void persistedKeysRoundTripUnchanged();
};

void TstConfigSecrets::saveWithoutSecretChangesTouchesTheStoreZeroTimes()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    FakeSecretStore *store = nullptr;
    const auto cfg = makeConfig(path, &store);

    // The geometry-save regression: an unrelated pref changes, save() runs,
    // and the store must not be touched at all.
    cfg->setWindowWidth(1234);
    cfg->save();
    QCOMPARE(store->calls.size(), 0);
    QVERIFY(cfg->secretsStatus().isEmpty());

    // Same after a load() — the state every real settings save starts from.
    cfg->load();
    store->calls.clear();
    cfg->setWindowWidth(1400);
    cfg->save();
    QCOMPARE(store->calls.size(), 0);
    QVERIFY(cfg->secretsStatus().isEmpty());
}

void TstConfigSecrets::changedNickservPasswordIsWrittenExactlyOnce()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    FakeSecretStore *store = nullptr;
    const auto cfg = makeConfig(path, &store);
    cfg->load();
    store->calls.clear();

    cfg->setNickservPassword(QStringLiteral("s3cret"));
    cfg->setNickservPassword(QStringLiteral("s3cret")); // same value: not dirty again
    cfg->save();

    QCOMPARE(store->calls.size(), 1);
    QCOMPARE(store->calls.front().op, QStringLiteral("write"));
    QCOMPARE(store->calls.front().secret, static_cast<int>(kirc::Secret::NickServPassword));
    QCOMPARE(store->calls.front().value, QStringLiteral("s3cret"));
    QVERIFY(cfg->secretsStatus().isEmpty());

    // The change is persisted: a follow-up save() makes no store call.
    store->calls.clear();
    cfg->save();
    QCOMPARE(store->calls.size(), 0);
}

void TstConfigSecrets::clearedNickservPasswordIsRemoved()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    FakeSecretStore *store = nullptr;
    const auto cfg = makeConfig(path, &store);

    cfg->setNickservPassword(QStringLiteral("x"));
    cfg->save(); // the write
    cfg->setNickservPassword(QString());
    cfg->save(); // the remove

    QCOMPARE(store->calls.size(), 2);
    QCOMPARE(store->calls.back().op, QStringLiteral("remove"));
    QCOMPARE(store->calls.back().secret, static_cast<int>(kirc::Secret::NickServPassword));
    QVERIFY(cfg->secretsStatus().isEmpty());

    store->calls.clear();
    cfg->save();
    QCOMPARE(store->calls.size(), 0);
}

void TstConfigSecrets::unavailableWriteKeepsValueDirtyAndReportsStatus()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    FakeSecretStore *store = nullptr;
    const auto cfg = makeConfig(path, &store);

    store->writeResult = kirc::SecretWriteResult::Unavailable;
    cfg->setNickservPassword(QStringLiteral("pw"));
    cfg->save();

    // Visible, plain-text failure status: names the backend, never the value.
    const QString status = cfg->secretsStatus();
    QVERIFY(!status.isEmpty());
    QVERIFY(status.contains(store->backendName()));
    QVERIFY(!status.contains(QStringLiteral("pw")));

    // The value stays in memory only (never falls back to plaintext), and
    // the dirty flag survives so the next save() retries the write.
    QCOMPARE(cfg->nickservPassword(), QStringLiteral("pw"));
    store->writeResult = kirc::SecretWriteResult::Ok;
    store->calls.clear();
    cfg->save();
    QCOMPARE(store->calls.size(), 1);
    QCOMPARE(store->calls.front().op, QStringLiteral("write"));
    QCOMPARE(store->calls.front().value, QStringLiteral("pw"));
    QVERIFY(cfg->secretsStatus().isEmpty());

    // The retry succeeded: nothing further to do.
    store->calls.clear();
    cfg->save();
    QCOMPARE(store->calls.size(), 0);
}

void TstConfigSecrets::legacyPlaintextPasswordMigratesIntoTheStore()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    writeFile(path, QStringLiteral("[Services]\nPassword=legacy\n"));

    FakeSecretStore *store = nullptr;
    const auto cfg = makeConfig(path, &store);
    store->readResult = kirc::SecretReadResult::NotFound;
    cfg->load();
    QCOMPARE(cfg->nickservPassword(), QStringLiteral("legacy"));

    store->calls.clear();
    cfg->save();
    // The migration write lands in the store exactly once.
    QCOMPARE(store->calls.size(), 1);
    QCOMPARE(store->calls.front().op, QStringLiteral("write"));
    QCOMPARE(store->calls.front().secret, static_cast<int>(kirc::Secret::NickServPassword));
    QCOMPARE(store->calls.front().value, QStringLiteral("legacy"));
    // And the plaintext key is gone from kirc.conf (no trace of the value).
    const QString text = readFile(path);
    QVERIFY(text.contains(QLatin1String("[Services]")));
    QVERIFY(!text.contains(QLatin1String("Password=")));
    QVERIFY(!text.contains(QLatin1String("legacy")));

    // A following load() reads it back from the store, not the file.
    FakeSecretStore *store2 = nullptr;
    const auto reread = makeConfig(path, &store2);
    store2->readResult = kirc::SecretReadResult::Found;
    store2->storedValue = QStringLiteral("legacy");
    reread->load();
    QCOMPARE(reread->nickservPassword(), QStringLiteral("legacy"));
}

void TstConfigSecrets::persistedKeysRoundTripUnchanged()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("kirc.conf"));
    FakeSecretStore *store = nullptr;
    const auto save = makeConfig(path, &store);

    save->setHost(QStringLiteral("irc.example.net"));
    save->setPort(7000);
    save->setTls(true);
    save->setNickname(QStringLiteral("tester"));
    save->setThemeId(QStringLiteral("bbs"));
    save->setFontDelta(3);
    save->setAutojoin(QStringLiteral("#a, #b"));
    save->setDefaultPartReason(QStringLiteral("brb"));
    save->setHistoryLimit(42);
    save->setReconnectLimit(0);
    save->setRespondToCtcpVersion(false);
    // The effect clamps are part of the persisted-key contract: what lands
    // on disk is the clamped value, and load() must not move it again.
    save->setGlassIntensity(250);  // clamps to 100
    save->setScanlineAmount(-10);  // clamps to 1
    save->save();

    FakeSecretStore *store2 = nullptr;
    const auto load = makeConfig(path, &store2);
    load->load();

    QCOMPARE(load->host(), QStringLiteral("irc.example.net"));
    QCOMPARE(load->port(), 7000);
    QCOMPARE(load->tls(), true);
    QCOMPARE(load->nickname(), QStringLiteral("tester"));
    QCOMPARE(load->themeId(), QStringLiteral("bbs"));
    QCOMPARE(load->fontDelta(), 3);
    QCOMPARE(load->autojoin(), QStringLiteral("#a, #b"));
    QCOMPARE(load->defaultPartReason(), QStringLiteral("brb"));
    QCOMPARE(load->historyLimit(), 42);
    QCOMPARE(load->reconnectLimit(), 0);
    QCOMPARE(load->respondToCtcpVersion(), false);
    QCOMPARE(load->glassIntensity(), 100);
    QCOMPARE(load->scanlineAmount(), 1);
}

QTEST_GUILESS_MAIN(TstConfigSecrets)
#include "tst_config_secrets.moc"
