/*
 *  Copyright (C) 2004-2026 Savoir-faire Linux Inc.
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
#pragma once

#include "account_manager.h"
#include "jamidht/auth_channel_handler.h"

#include <dhtnet/multiplexed_socket.h>
#include <opendht/dhtrunner.h>
#include <memory>

namespace jami {

// Internal one-shot test seam. The hook runs while a revoke operation owns the
// archive transaction, after reading the latest archive and before saving it.
void setArchiveRevokeTransactionHookForTesting(std::function<void()> hook);

// used for status codes on DeviceAuthStateChanged
enum class DeviceAuthState : uint8_t {
    INIT = 0,
    TOKEN_AVAILABLE = 1,
    CONNECTING = 2,
    AUTHENTICATING = 3,
    IN_PROGRESS = 4,
    DONE = 5,
};

class ArchiveAccountManager : public AccountManager
{
public:
    using OnExportConfig = std::function<std::map<std::string, std::string>()>;
    using OnSyncData = std::function<void(DeviceSync&&)>;

    ArchiveAccountManager(const std::string& accountId,
                          const std::filesystem::path& path,
                          OnExportConfig&& onExportConfig,
                          OnSyncData&& onSyncData,
                          std::string archivePath,
                          const std::string& nameServer)
        : AccountManager(accountId, path, nameServer)
        , onExportConfig_(std::move(onExportConfig))
        , onSyncData_(std::move(onSyncData))
        , archivePath_(std::move(archivePath))
    {}

    struct ArchiveAccountCredentials : AccountCredentials
    {
        in_port_t dhtPort {0};
        std::vector<std::string> dhtBootstrap;
        dht::crypto::Identity updateIdentity;
        // The temporary pairing endpoint follows the chosen account policy.
        // Supplying its DHT prevents ConnectionManager's default bootstrap.
        dht::DhtRunner::Config pairingDht;
        std::shared_ptr<dhtnet::ConnectionManager::Config> pairingConnection;
    };

    void initAuthentication(std::string deviceName,
                            std::unique_ptr<AccountCredentials> credentials,
                            AuthSuccessCallback onSuccess,
                            AuthFailureCallback onFailure,
                            const OnChangeCallback& onChange) override;

    bool changePassword(const std::string& password_old, const std::string& password_new) override;
    virtual std::vector<uint8_t> getPasswordKey(const std::string& /*password*/) override;

    void syncDevices() override;

    int32_t addDevice(const std::string& uri, std::string_view auth_scheme, AuthChannelHandler*) override;
    bool cancelAddDevice(uint32_t token) override;
    bool confirmAddDevice(uint32_t token) override;
    std::string confirmAddDeviceWithCode(uint32_t token, const std::string& localArchiveSecret);
    bool completeDeviceLinkPreparation(uint32_t token);
    bool hasPendingDeviceLink() const;

    bool revokeDevice(const std::string& device,
                      std::string_view scheme,
                      const std::string& password,
                      RevokeDeviceCallback) override;
    bool exportArchive(const std::string& destinationPath, std::string_view scheme, const std::string& password);
    bool exportArchive(const std::string& destinationPath,
                       std::string_view inputScheme,
                       const std::string& inputPassword,
                       std::string_view outputScheme,
                       const std::string& outputPassword);
    bool isPasswordValid(const std::string& password) override;

    bool provideAccountAuthentication(const std::string& credentialsFromUser, const std::string& scheme);

    void registerName(const std::string& name,
                      std::string_view scheme,
                      const std::string& password,
                      RegistrationCallback cb) override;

    /**
     * Change the validity of a certificate. If hash is empty, update all certificates
     */
    bool setValidity(std::string_view scheme,
                     const std::string& password,
                     dht::crypto::Identity& device,
                     const dht::InfoHash& id,
                     int64_t validity);

    // for linking devices
    void onAuthReady(const std::string& deviceId, std::shared_ptr<dhtnet::ChannelSocket> channel);

private:
    struct DeviceContextBase;
    struct AddDeviceContext;
    struct LinkDeviceContext;
    struct AuthContext
    {
        std::recursive_mutex mutex;
        std::string accountId;
        uint32_t token {0};
        PrivateKey key;
        CertRequest request;
        std::string deviceName;
        std::unique_ptr<ArchiveAccountCredentials> credentials;
        std::shared_ptr<LinkDeviceContext> linkDevCtx;  // New device
        std::shared_ptr<AddDeviceContext> addDeviceCtx; // Source device
        AuthSuccessCallback onSuccess;
        AuthFailureCallback onFailure;
        std::unique_ptr<asio::steady_timer> timeout;
        bool canceled {false};
        bool terminal {false};
        std::chrono::steady_clock::time_point deadline;
        std::string expectedPeerDevice;
        std::string expectedPeerAccount;
        std::string pairingCode;
        std::string immutableArchive;
        std::string preparedDeviceId;
    };
    struct DeviceAuthInfo;
    std::shared_ptr<AuthContext> authCtx_;
    bool ownsPairing(const std::shared_ptr<AuthContext>& ctx) const;
    bool claimPairing(const std::shared_ptr<AuthContext>& ctx);
    void finishPairing(const std::shared_ptr<AuthContext>& ctx, const std::string& error);
    void armPairingDeadline(const std::shared_ptr<AuthContext>& ctx);

    void createAccount(AuthContext& ctx);

    std::pair<std::string, std::shared_ptr<dht::Value>> makeReceipt(const dht::crypto::Identity& id,
                                                                    const dht::crypto::Certificate& device,
                                                                    const std::string& ethAccount);
    void updateArchive(AccountArchive& content /*, const ContactList& syncData*/) const;
    AccountArchive readArchive(std::string_view scheme, const std::string& password) const;
    AccountArchive readArchiveUnlocked(std::string_view scheme, const std::string& password) const;
    bool saveArchiveUnlocked(AccountArchive& content, std::string_view scheme, const std::string& pwd);
    static std::pair<std::vector<uint8_t>, dht::InfoHash> computeKeys(const std::string& password,
                                                                      const std::string& pin,
                                                                      bool previous = false);
    bool updateCertificates(AccountArchive& archive, dht::crypto::Identity& device);
    static bool needsMigration(const std::string& accountId, const dht::crypto::Identity& id);

    void loadFromFile(AuthContext& ctx);
    void loadFromLocalArchive(AuthContext& ctx);

    // for linking devices
    void startLoadArchiveFromDevice(const std::shared_ptr<AuthContext>& ctx);

    bool doAddDevice(std::string_view scheme,
                     const std::shared_ptr<AuthContext>& ctx,
                     std::shared_ptr<dhtnet::ChannelSocket> channel);

    void onArchiveLoaded(AuthContext& ctx, AccountArchive&& a, bool isLinkDevProtocol);

    inline std::weak_ptr<ArchiveAccountManager> weak()
    {
        return std::static_pointer_cast<ArchiveAccountManager>(shared_from_this());
    }

    OnExportConfig onExportConfig_;
    OnSyncData onSyncData_;
    mutable std::mutex archiveMutex_;
    std::string archivePath_;
};

} // namespace jami
