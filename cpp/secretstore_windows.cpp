// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Windows Credential Manager backend of the kIRC secret store.
//
// Generic credentials (CRED_TYPE_GENERIC) with stable target names:
//   org.kde.kirc/nickserv-password
//   org.kde.kirc/server-password
// The blob is the UTF-16LE encoding of the password with no terminating
// NUL (readers validate the byte length instead of relying on one).
// Persisted per user with CRED_PERSIST_LOCAL_MACHINE — available across
// that user's logons, never enterprise-roaming.

#include "secretstore.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wincred.h>

namespace {

wchar_t *targetForSecret(kirc::Secret secret)
{
    switch (secret) {
    case kirc::Secret::NickServPassword:
        return const_cast<wchar_t *>(L"org.kde.kirc/nickserv-password");
    case kirc::Secret::ServerPassword:
        return const_cast<wchar_t *>(L"org.kde.kirc/server-password");
    }
    return nullptr;
}

class WindowsSecretStore final : public kirc::SecretStore
{
public:
    kirc::SecretReadResult read(kirc::Secret secret, QString *value) override
    {
        PCREDENTIALW cred = nullptr;
        if (!CredReadW(targetForSecret(secret), CRED_TYPE_GENERIC, 0, &cred)) {
            const DWORD err = GetLastError();
            if (err == ERROR_NOT_FOUND) {
                return kirc::SecretReadResult::NotFound;
            }
            return kirc::SecretReadResult::Unavailable;
        }
        QString result;
        if (cred->CredentialBlobSize > 0) {
            if (cred->CredentialBlobSize % sizeof(wchar_t) != 0) {
                CredFree(cred);
                return kirc::SecretReadResult::Error;
            }
            const int chars = int(cred->CredentialBlobSize / sizeof(wchar_t));
            result = QString::fromWCharArray(reinterpret_cast<const wchar_t *>(cred->CredentialBlob), chars);
        }
        CredFree(cred);
        *value = result;
        return kirc::SecretReadResult::Found;
    }

    kirc::SecretWriteResult write(kirc::Secret secret, const QString &value) override
    {
        const DWORD blobBytes = DWORD(value.size()) * sizeof(wchar_t);
        if (blobBytes > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
            return kirc::SecretWriteResult::Error;
        }
        CREDENTIALW cred = {};
        cred.Type = CRED_TYPE_GENERIC;
        cred.TargetName = targetForSecret(secret);
        cred.UserName = const_cast<wchar_t *>(L"kIRC");
        cred.CredentialBlob = const_cast<BYTE *>(reinterpret_cast<const BYTE *>(value.utf16()));
        cred.CredentialBlobSize = blobBytes;
        cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
        if (!CredWriteW(&cred, 0)) {
            return kirc::SecretWriteResult::Error;
        }
        return kirc::SecretWriteResult::Ok;
    }

    kirc::SecretWriteResult remove(kirc::Secret secret) override
    {
        if (!CredDeleteW(targetForSecret(secret), CRED_TYPE_GENERIC, 0)) {
            const DWORD err = GetLastError();
            if (err == ERROR_NOT_FOUND) {
                // Removing something that is not there is the requested
                // end state; KWallet's guarded remove behaves the same.
                return kirc::SecretWriteResult::Ok;
            }
            return kirc::SecretWriteResult::Error;
        }
        return kirc::SecretWriteResult::Ok;
    }

    QString backendName() const override
    {
        return QStringLiteral("Windows Credential Manager");
    }
};

} // namespace

namespace kirc {

std::unique_ptr<SecretStore> makeSecretStore()
{
    return std::make_unique<WindowsSecretStore>();
}

} // namespace kirc
