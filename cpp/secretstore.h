// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Platform secret storage for kIRC's two persisted secrets: the NickServ
// password and the IRC server password (PASS).
//
// Linux backend: KWallet, folder "kIRC", keys "nickserv-password" and
// "server-password" (the locations every existing kIRC installation uses).
// Windows backend: Credential Manager generic credentials with the stable
// target names "org.kde.kirc/nickserv-password" and
// "org.kde.kirc/server-password".
//
// Contract (see also KircConfig's header):
//   * read() reports Found/NotFound/Unavailable/Error; `value` is only
//     written on Found. A stored empty string is Found with "" and is
//     distinct from NotFound.
//   * write()/remove() report Ok/Unavailable/Error. remove() of a missing
//     entry is Ok (idempotent), matching the KWallet no-op behaviour.
//   * A backend that is locked or missing (no wallet daemon, credential
//     service error) reports Unavailable; callers then keep the value in
//     memory for the current process only and never fall back to plaintext.

#ifndef KIRC_SECRETSTORE_H
#define KIRC_SECRETSTORE_H

#include <QString>

#include <memory>

namespace kirc {

/// Which secret to read or write. Backends map this to their own physical
/// location; callers never handle backend-specific key names.
enum class Secret {
    NickServPassword,
    ServerPassword,
};

enum class SecretReadResult {
    Found,
    NotFound,
    Unavailable,
    Error,
};

enum class SecretWriteResult {
    Ok,
    Unavailable,
    Error,
};

class SecretStore
{
public:
    virtual ~SecretStore() = default;

    virtual SecretReadResult read(Secret secret, QString *value) = 0;
    virtual SecretWriteResult write(Secret secret, const QString &value) = 0;
    virtual SecretWriteResult remove(Secret secret) = 0;

    /// Backend name for user-visible wording (About/settings pages). Never
    /// claim KWallet on Windows.
    virtual QString backendName() const = 0;
};

/// Creates the platform secret store. Exactly one implementation is linked
/// per build (KWallet on Linux, Credential Manager on Windows).
std::unique_ptr<SecretStore> makeSecretStore();

} // namespace kirc

#endif // KIRC_SECRETSTORE_H
