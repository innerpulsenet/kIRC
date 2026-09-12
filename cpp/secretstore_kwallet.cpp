// SPDX-License-Identifier: MIT OR Apache-2.0
//
// KWallet backend of the kIRC secret store (Linux). Behaviour-preserving
// port of the helpers that used to live in kircconfig.cpp: same wallet
// (LocalWallet, synchronous), same folder ("kIRC"), same short key names,
// so existing installations see no difference.

#include "secretstore.h"

#include <KWallet>

namespace {

constexpr auto kWalletFolder = "kIRC";

QString keyForSecret(kirc::Secret secret)
{
    switch (secret) {
    case kirc::Secret::NickServPassword:
        return QStringLiteral("nickserv-password");
    case kirc::Secret::ServerPassword:
        return QStringLiteral("server-password");
    }
    return QString();
}

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

class KWalletSecretStore final : public kirc::SecretStore
{
public:
    kirc::SecretReadResult read(kirc::Secret secret, QString *value) override
    {
        KWallet::Wallet *wallet = openKircWallet();
        if (!wallet) {
            return kirc::SecretReadResult::Unavailable;
        }
        QString stored;
        const int rc = wallet->readPassword(keyForSecret(secret), stored);
        delete wallet;
        if (rc != 0) {
            // KWallet reports a missing entry and every other failure the
            // same way; kircconfig's legacy-migration fallback treats both
            // as "nothing stored", so keep that meaning here.
            return kirc::SecretReadResult::NotFound;
        }
        *value = stored;
        return kirc::SecretReadResult::Found;
    }

    kirc::SecretWriteResult write(kirc::Secret secret, const QString &value) override
    {
        KWallet::Wallet *wallet = openKircWallet();
        if (!wallet) {
            return kirc::SecretWriteResult::Unavailable;
        }
        const int rc = wallet->writePassword(keyForSecret(secret), value);
        delete wallet;
        return rc == 0 ? kirc::SecretWriteResult::Ok : kirc::SecretWriteResult::Error;
    }

    kirc::SecretWriteResult remove(kirc::Secret secret) override
    {
        KWallet::Wallet *wallet = openKircWallet();
        if (!wallet) {
            return kirc::SecretWriteResult::Unavailable;
        }
        if (wallet->hasEntry(keyForSecret(secret))) {
            wallet->removeEntry(keyForSecret(secret));
        }
        delete wallet;
        return kirc::SecretWriteResult::Ok;
    }

    QString backendName() const override
    {
        return QStringLiteral("KWallet");
    }
};

} // namespace

namespace kirc {

std::unique_ptr<SecretStore> makeSecretStore()
{
    return std::make_unique<KWalletSecretStore>();
}

} // namespace kirc
