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
#include "archive_account_manager.h"
#include "accountarchive.h"
#include "fileutils.h"
#include "libdevcrypto/Common.h"
#include "archiver.h"
#include "base64.h"
#include "jami/account_const.h"
#include "account_schema.h"
#include "jamidht/conversation_module.h"
#include "manager.h"
#include "jamidht/auth_channel_handler.h"
#include "client/jami_signal.h"

#include <dhtnet/multiplexed_socket.h>
#include <dhtnet/channel_utils.h>
#include <opendht/dhtrunner.h>
#include <opendht/thread_pool.h>

#include <memory>
#include <fstream>
#include <thread>
#include <utility>

#include "config/yamlparser.h"

namespace jami {

const constexpr auto EXPORT_KEY_RENEWAL_TIME = std::chrono::minutes(20);

namespace {

std::mutex archiveRevokeHookMutex;
std::function<void()> archiveRevokeHook;

// A new certificate is sometimes reported as NOT_ACTIVATED during the clock
// tick in which it was signed. Keep the original signed chain and withhold
// account admission/publication until normal verification accepts it. Other
// certificate failures fail immediately; a stalled clock fails closed.
void
waitForCertificateActivation(const std::shared_ptr<dht::crypto::Certificate>& certificate)
{
    if (!certificate)
        throw std::runtime_error("Missing device certificate");
    auto root = certificate;
    while (root->issuer)
        root = root->issuer;
    dht::crypto::TrustList trust;
    trust.add(*root);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    for (;;) {
        const auto result = trust.verify(*certificate);
        if (result)
            return;
        if (result.ret < 0
            || (result.result & ~(GNUTLS_CERT_INVALID | GNUTLS_CERT_NOT_ACTIVATED)) != 0
            || std::chrono::steady_clock::now() >= deadline)
            throw std::runtime_error("New device certificate chain is not valid");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

std::function<void()>
takeArchiveRevokeTransactionHookForTesting()
{
    std::lock_guard lock(archiveRevokeHookMutex);
    return std::exchange(archiveRevokeHook, {});
}

} // namespace

void
setArchiveRevokeTransactionHookForTesting(std::function<void()> hook)
{
    std::lock_guard lock(archiveRevokeHookMutex);
    archiveRevokeHook = std::move(hook);
}

void
ArchiveAccountManager::initAuthentication(std::string deviceName,
                                          std::unique_ptr<AccountCredentials> credentials,
                                          AuthSuccessCallback onSuccess,
                                          AuthFailureCallback onFailure,
                                          const OnChangeCallback& onChange)
{
    JAMI_WARNING("[Account {}] [Auth] starting authentication with scheme '{}'", accountId_, credentials->scheme);
    auto ctx = std::make_shared<AuthContext>();
    ctx->accountId = accountId_;
    ctx->key = dht::ThreadPool::computation().getShared<std::shared_ptr<dht::crypto::PrivateKey>>(
        []() { return std::make_shared<dht::crypto::PrivateKey>(dht::crypto::PrivateKey::generate()); });
    ctx->request = buildRequest(ctx->key);
    ctx->deviceName = std::move(deviceName);
    ctx->credentials = dynamic_unique_cast<ArchiveAccountCredentials>(std::move(credentials));
    ctx->onSuccess = std::move(onSuccess);
    ctx->onFailure = std::move(onFailure);

    if (not ctx->credentials) {
        ctx->onFailure(AuthError::INVALID_ARGUMENTS, "invalid credentials");
        return;
    }
    onChange_ = std::move(onChange);

    if (ctx->credentials->scheme == "p2p") {
        JAMI_DEBUG("[LinkDevice] Importing account via p2p scheme.");
        startLoadArchiveFromDevice(ctx);
        return;
    }

    dht::ThreadPool::computation().run([ctx = std::move(ctx), wthis = weak()] {
        auto this_ = wthis.lock();
        if (not this_)
            return;
        try {
            if (ctx->credentials->scheme == "file") {
                // Import from external archive
                this_->loadFromFile(*ctx);
            } else {
                // Create/migrate local account
                bool hasArchive = not ctx->credentials->uri.empty()
                                  and std::filesystem::is_regular_file(ctx->credentials->uri);
                if (hasArchive) {
                    this_->loadFromLocalArchive(*ctx);
                } else if (ctx->credentials->updateIdentity.first and ctx->credentials->updateIdentity.second) {
                    auto future_keypair = dht::ThreadPool::computation().get<dev::KeyPair>(&dev::KeyPair::create);
                    AccountArchive a;
                    JAMI_WARNING("[Account {}] [Auth] Converting certificate from old account {}",
                                 this_->accountId_,
                                 ctx->credentials->updateIdentity.first->getPublicKey().getId().to_view());
                    a.id = std::move(ctx->credentials->updateIdentity);
                    try {
                        a.ca_key = std::make_shared<dht::crypto::PrivateKey>(
                            fileutils::loadFile("ca.key", this_->path_));
                    } catch (...) {
                    }
                    this_->updateCertificates(a, ctx->credentials->updateIdentity);
                    a.eth_key = future_keypair.get().secret().makeInsecure().asBytes();
                    this_->onArchiveLoaded(*ctx, std::move(a), false);
                } else {
                    this_->createAccount(*ctx);
                }
            }
        } catch (const std::exception& e) {
            ctx->onFailure(AuthError::UNKNOWN, e.what());
        }
    });
}

bool
ArchiveAccountManager::updateCertificates(AccountArchive& archive, dht::crypto::Identity& device)
{
    JAMI_WARNING("[Account {}] [Auth] Updating certificates", accountId_);
    using Certificate = dht::crypto::Certificate;

    // We need the CA key to resign certificates
    if (not archive.id.first or not *archive.id.first or not archive.id.second or not archive.ca_key
        or not *archive.ca_key)
        return false;

    // Currently set the CA flag and update expiration dates
    bool updated = false;

    auto& cert = archive.id.second;
    auto ca = cert->issuer;
    // Update CA if possible and relevant
    if (not ca or (not ca->issuer and (not ca->isCA() or ca->getExpiration() < clock::now()))) {
        ca = std::make_shared<Certificate>(Certificate::generate(*archive.ca_key, "Jami CA", {}, true));
        updated = true;
        JAMI_LOG("[Account {}] [Auth] CA certificate re-generated", accountId_);
    }

    // Update certificate
    if (updated or not cert->isCA() or cert->getExpiration() < clock::now()) {
        cert = std::make_shared<Certificate>(
            Certificate::generate(*archive.id.first, "Jami", dht::crypto::Identity {archive.ca_key, ca}, true));
        updated = true;
        JAMI_LOG("[Account {}] [Auth] Account certificate for {} re-generated", accountId_, cert->getId());
    }

    if (updated and device.first and *device.first) {
        // update device certificate
        device.second = std::make_shared<Certificate>(Certificate::generate(*device.first, "Jami device", archive.id));
        JAMI_LOG("[Account {}] [Auth] Device certificate re-generated", accountId_);
    }

    return updated;
}

bool
ArchiveAccountManager::setValidity(std::string_view scheme,
                                   const std::string& password,
                                   dht::crypto::Identity& device,
                                   const dht::InfoHash& id,
                                   int64_t validity)
{
    std::lock_guard lock(archiveMutex_);
    auto archive = readArchiveUnlocked(scheme, password);
    // We need the CA key to resign certificates
    if (not archive.id.first or not *archive.id.first or not archive.id.second or not archive.ca_key
        or not *archive.ca_key)
        return false;

    auto updated = false;

    if (id)
        JAMI_WARNING("[Account {}] [Auth] Updating validity for certificate with id: {}", accountId_, id);
    else
        JAMI_WARNING("[Account {}] [Auth] Updating validity for certificates", accountId_);

    auto& cert = archive.id.second;
    auto ca = cert->issuer;
    if (not ca)
        return false;

    // using Certificate = dht::crypto::Certificate;
    //  Update CA if possible and relevant
    if (not id or ca->getId() == id) {
        ca->setValidity(*archive.ca_key, validity);
        updated = true;
        JAMI_LOG("[Account {}] [Auth] CA certificate re-generated", accountId_);
    }

    // Update certificate
    if (updated or not id or cert->getId() == id) {
        cert->setValidity(dht::crypto::Identity {archive.ca_key, ca}, validity);
        device.second->issuer = cert;
        updated = true;
        JAMI_LOG("[Account {}] [Auth] Jami certificate re-generated", accountId_);
    }

    if (updated) {
        if (!archive.save(fileutils::getFullPath(path_, archivePath_), scheme, password))
            return false;
    }

    if (updated or not id or device.second->getId() == id) {
        // update device certificate
        device.second->setValidity(archive.id, validity);
        updated = true;
    }

    return updated;
}

void
ArchiveAccountManager::createAccount(AuthContext& ctx)
{
    AccountArchive a;
    auto ca = dht::crypto::generateIdentity("Jami CA");
    if (!ca.first || !ca.second) {
        throw std::runtime_error("Unable to generate CA for this account.");
    }
    a.id = dht::crypto::generateIdentity("Jami", ca, 4096, true);
    if (!a.id.first || !a.id.second) {
        throw std::runtime_error("Unable to generate identity for this account.");
    }
    JAMI_WARNING("[Account {}] [Auth] New account: CA: {}, ID: {}",
                 accountId_,
                 ca.second->getId(),
                 a.id.second->getId());
    a.ca_key = ca.first;
    auto keypair = dev::KeyPair::create();
    a.eth_key = keypair.secret().makeInsecure().asBytes();
    onArchiveLoaded(ctx, std::move(a), false);
}

void
ArchiveAccountManager::loadFromFile(AuthContext& ctx)
{
    JAMI_WARNING("[Account {}] [Auth] Loading archive from: {}", accountId_, ctx.credentials->uri.c_str());
    AccountArchive archive;
    try {
        archive = AccountArchive(ctx.credentials->uri, ctx.credentials->password_scheme, ctx.credentials->password);
    } catch (const std::exception& ex) {
        JAMI_WARNING("[Account {}] [Auth] Unable to read archive file: {}", accountId_, ex.what());
        ctx.onFailure(AuthError::INVALID_ARGUMENTS, ex.what());
        return;
    }
    onArchiveLoaded(ctx, std::move(archive), false);
}

void
ArchiveAccountManager::loadFromLocalArchive(AuthContext& ctx)
{
    JAMI_WARNING("[Account {}] [Auth] Loading local archive from: {}", accountId_, ctx.credentials->uri.c_str());
    AccountArchive archive;
    try {
        archive = AccountArchive(ctx.credentials->uri, ctx.credentials->password_scheme, ctx.credentials->password);
    } catch (const std::exception& ex) {
        JAMI_WARNING("[Account {}] [Auth] Unable to read archive file: {}", accountId_, ex.what());
        ctx.onFailure(AuthError::INVALID_ARGUMENTS, ex.what());
        return;
    }

    updateArchive(archive);

    if (ctx.credentials->updateIdentity.first and ctx.credentials->updateIdentity.second
        and needsMigration(accountId_, ctx.credentials->updateIdentity)) {
        JAMI_WARNING("[Account {}] [Auth] Account migration needed", accountId_);
        if (not updateCertificates(archive, ctx.credentials->updateIdentity)) {
            ctx.onFailure(AuthError::UNKNOWN, "");
            return;
        }
    }

    onArchiveLoaded(ctx, std::move(archive), false);
}

void
ArchiveAccountManager::onArchiveLoaded(AuthContext& ctx, AccountArchive&& a, bool isLinkDevProtocol)
{
    auto ethAccount = dev::KeyPair(dev::Secret(a.eth_key)).address().hex();
    dhtnet::fileutils::check_dir(path_, 0700);

    if (isLinkDevProtocol && (!ctx.credentials || ctx.credentials->password.empty() ||
        ctx.credentials->password_scheme != fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD))
        throw std::runtime_error("Linked archive requires installation protection");
    a.config[libjami::Account::ConfProperties::ARCHIVE_HAS_PASSWORD] =
        ctx.credentials->password_scheme.empty() ? FALSE_STR : TRUE_STR;
    if (isLinkDevProtocol) a.config[libjami::Account::ConfProperties::ENABLED] = FALSE_STR;
    {
        std::lock_guard lock(archiveMutex_);
        if (!a.save(fileutils::getFullPath(path_, archivePath_),
                    ctx.credentials->password_scheme, ctx.credentials->password))
            throw std::runtime_error("Unable to durably save account archive");
    }

    if (not a.id.second->isCA()) {
        JAMI_ERROR("[Account {}] [Auth] Attempting to sign a certificate with a non-CA.", accountId_);
    }

    std::shared_ptr<dht::crypto::Certificate> deviceCertificate;
    std::unique_ptr<ContactList> contacts;
    auto usePreviousIdentity = false;
    // If updateIdentity got a valid certificate, there is no need for a new cert
    if (auto oldId = ctx.credentials->updateIdentity.second) {
        contacts = std::make_unique<ContactList>(ctx.accountId, oldId, path_, onChange_);
        if (contacts->isValidAccountDevice(*oldId) && ctx.credentials->updateIdentity.first) {
            deviceCertificate = oldId;
            usePreviousIdentity = true;
            JAMI_WARNING("[Account {}] [Auth] Using previously generated device certificate {}",
                         accountId_,
                         deviceCertificate->getLongId());
        } else {
            contacts.reset();
        }
    }

    // Generate a new device if needed
    if (!deviceCertificate) {
        JAMI_WARNING("[Account {}] [Auth] Creating new device certificate", accountId_);
        auto request = ctx.request.get();
        if (not request->verify()) {
            JAMI_ERROR("[Account {}] [Auth] Invalid certificate request.", accountId_);
            ctx.onFailure(AuthError::INVALID_ARGUMENTS, "");
            return;
        }
        deviceCertificate = std::make_shared<dht::crypto::Certificate>(
            dht::crypto::Certificate::generate(*request, a.id));
        JAMI_WARNING("[Account {}] [Auth] Created new device: {}", accountId_, deviceCertificate->getLongId());
    }
    waitForCertificateActivation(deviceCertificate);

    auto receipt = makeReceipt(a.id, *deviceCertificate, ethAccount);
    auto receiptSignature = a.id.first->sign(receipt.first);

    auto info = std::make_unique<AccountInfo>();
    auto pk = usePreviousIdentity ? ctx.credentials->updateIdentity.first : ctx.key.get();
    auto sharedPk = pk->getSharedPublicKey();
    info->identity.first = pk;
    info->identity.second = deviceCertificate;
    info->accountId = a.id.second->getId().toString();
    info->devicePk = sharedPk;
    info->deviceId = info->devicePk->getLongId().toString();
    if (ctx.deviceName.empty())
        ctx.deviceName = info->deviceId.substr(8);

    if (!contacts) {
        contacts = std::make_unique<ContactList>(ctx.accountId, a.id.second, path_, onChange_);
    }
    info->contacts = std::move(contacts);
    info->contacts->setContacts(a.contacts);
    info->contacts->foundAccountDevice(deviceCertificate, ctx.deviceName, clock::now());
    info->ethAccount = ethAccount;
    info->announce = std::move(receipt.second);
    ConversationModule::saveConvInfosToPath(path_, a.conversations);
    ConversationModule::saveConvRequestsToPath(path_, a.conversationsRequests);
    info_ = std::move(info);

    ctx.onSuccess(*info_, std::move(a.config), std::move(receipt.first), std::move(receiptSignature));
}

std::pair<std::vector<uint8_t>, dht::InfoHash>
ArchiveAccountManager::computeKeys(const std::string& password, const std::string& pin, bool previous)
{
    // Compute time seed
    auto now = std::chrono::duration_cast<std::chrono::seconds>(clock::now().time_since_epoch());
    auto tseed = now.count() / std::chrono::seconds(EXPORT_KEY_RENEWAL_TIME).count();
    if (previous)
        tseed--;
    std::ostringstream ss;
    ss << std::hex << tseed;
    auto tseed_str = ss.str();

    // Generate key for archive encryption, using PIN as the salt
    std::vector<uint8_t> salt_key;
    salt_key.reserve(pin.size() + tseed_str.size());
    salt_key.insert(salt_key.end(), pin.begin(), pin.end());
    salt_key.insert(salt_key.end(), tseed_str.begin(), tseed_str.end());
    auto key = dht::crypto::stretchKey(password, salt_key, 256 / 8);

    // Generate public storage location as SHA1(key).
    auto loc = dht::InfoHash::get(key);

    return {key, loc};
}

std::pair<std::string, std::shared_ptr<dht::Value>>
ArchiveAccountManager::makeReceipt(const dht::crypto::Identity& id,
                                   const dht::crypto::Certificate& device,
                                   const std::string& ethAccount)
{
    JAMI_LOG("[Account {}] [Auth] Signing receipt for device {}", accountId_, device.getLongId());
    auto devId = device.getId();
    DeviceAnnouncement announcement;
    announcement.dev = devId;
    announcement.pk = device.getSharedPublicKey();
    dht::Value ann_val {announcement};
    ann_val.priority = 1; // normal priority — presence updates should not wake peers
    ann_val.sign(*id.first);

    auto packedAnnoucement = ann_val.getPacked();
    JAMI_LOG("[Account {}] [Auth] Device announcement size: {}", accountId_, packedAnnoucement.size());

    std::ostringstream is;
    is << "{\"id\":\"" << id.second->getId() << "\",\"dev\":\"" << devId << "\",\"eth\":\"" << ethAccount
       << "\",\"announce\":\"" << base64::encode(packedAnnoucement) << "\"}";

    // auto announce_ = ;
    return {is.str(), std::make_shared<dht::Value>(std::move(ann_val))};
}

bool
ArchiveAccountManager::needsMigration(const std::string& accountId, const dht::crypto::Identity& id)
{
    if (not id.second)
        return true;
    auto cert = id.second->issuer;
    while (cert) {
        if (not cert->isCA()) {
            JAMI_WARNING("[Account {}] [Auth] certificate {} is not a CA, needs update.", accountId, cert->getId());
            return true;
        }
        if (cert->getExpiration() < clock::now()) {
            JAMI_WARNING("[Account {}] [Auth] certificate {} is expired, needs update.", accountId, cert->getId());
            return true;
        }
        cert = cert->issuer;
    }
    return false;
}

void
ArchiveAccountManager::syncDevices()
{
    JAMI_LOG("[Account {}] Building device sync from {}", accountId_, info_->deviceId);
    onSyncData_(info_->contacts->getSyncData());
}

AccountArchive
ArchiveAccountManager::readArchive(std::string_view scheme, const std::string& pwd) const
{
    std::lock_guard lock(archiveMutex_);
    return readArchiveUnlocked(scheme, pwd);
}

AccountArchive
ArchiveAccountManager::readArchiveUnlocked(std::string_view scheme, const std::string& pwd) const
{
    JAMI_LOG("[Account {}] [Auth] Reading account archive", accountId_);
    return AccountArchive(fileutils::getFullPath(path_, archivePath_), scheme, pwd);
}

void
ArchiveAccountManager::updateArchive(AccountArchive& archive) const
{
    using namespace libjami::Account::ConfProperties;

    // Keys not exported to archive
    static const auto filtered_keys = {Ringtone::PATH,
                                       ARCHIVE_PATH,
                                       DEVICE_ID,
                                       DEVICE_NAME,
                                       Conf::CONFIG_DHT_PORT,
                                       DHT_PROXY_LIST_URL,
                                       AUTOANSWER,
                                       PROXY_ENABLED,
                                       PROXY_SERVER,
                                       PROXY_PUSH_TOKEN,
                                       TLS::CA_LIST_FILE,
                                       TLS::CERTIFICATE_FILE,
                                       TLS::PRIVATE_KEY_FILE};

    JAMI_LOG("[Account {}] [Auth] Building account archive", accountId_);
    for (const auto& it : onExportConfig_()) {
        // filter-out?
        if (std::any_of(std::begin(filtered_keys), std::end(filtered_keys), [&](const auto& key) {
                return key == it.first;
            }))
            continue;

        archive.config[it.first] = it.second;
    }

    // Note we do not know accountID_ here, use path
    archive.contacts = ContactList::contactsFromPath(path_);
    archive.conversations = ConversationModule::convInfosFromPath(path_);
    archive.conversationsRequests = ConversationModule::convRequestsFromPath(path_);
}

bool
ArchiveAccountManager::saveArchiveUnlocked(AccountArchive& archive, std::string_view scheme, const std::string& pwd)
{
    try {
        updateArchive(archive);
        if (archivePath_.empty())
            archivePath_ = "export.gz";
        return archive.save(fileutils::getFullPath(path_, archivePath_), scheme, pwd);
    } catch (const std::runtime_error& ex) {
        JAMI_ERROR("[Account {}] [Auth] Unable to export archive: {}", accountId_, ex.what());
        return false;
    }
}

bool
ArchiveAccountManager::changePassword(const std::string& password_old, const std::string& password_new)
{
    std::lock_guard lock(archiveMutex_);
    try {
        auto path = fileutils::getFullPath(path_, archivePath_);
        return AccountArchive(path, fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD, password_old)
            .save(path, fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD, password_new);
    } catch (const std::exception&) {
        return false;
    }
}

std::vector<uint8_t>
ArchiveAccountManager::getPasswordKey(const std::string& password)
{
    std::lock_guard lock(archiveMutex_);
    try {
        auto data = dhtnet::fileutils::loadFile(fileutils::getFullPath(path_, archivePath_));
        // Try to decrypt to check if password is valid
        auto key = dht::crypto::aesGetKey(data, password);
        auto decrypted = dht::crypto::aesDecrypt(dht::crypto::aesGetEncrypted(data), key);
        return key;
    } catch (const std::exception& e) {
        JAMI_ERROR("[Account {}] Error loading archive: {}", accountId_, e.what());
    }
    return {};
}

bool
ArchiveAccountManager::revokeDevice(const std::string& device,
                                    std::string_view scheme,
                                    const std::string& password,
                                    RevokeDeviceCallback cb)
{
    findCertificate(DeviceId(device),
                    [scheme = std::string(scheme), password, device, cb, w = weak()](
                        const std::shared_ptr<dht::crypto::Certificate>& crt) mutable {
                        if (not crt) {
                            cb(RevokeDeviceResult::ERROR_NETWORK);
                            return;
                        }
                        auto this_ = w.lock();
                        if (not this_)
                            return;
                        AccountArchive a;
                        try {
                            // Read the latest archive only after the network
                            // lookup completes, then keep the read-modify-write
                            // under one archive transaction. A snapshot taken
                            // before the lookup could overwrite a password
                            // change or another completed archive update.
                            std::lock_guard lock(this_->archiveMutex_);
                            a = this_->readArchiveUnlocked(scheme, password);
                            if (auto hook = takeArchiveRevokeTransactionHookForTesting())
                                hook();
                            if (not a.revoked)
                                a.revoked = std::make_shared<decltype(a.revoked)::element_type>();
                            a.revoked->revoke(*crt);
                            a.revoked->sign(a.id);
                            if (!this_->saveArchiveUnlocked(a, scheme, password)) {
                                cb(RevokeDeviceResult::ERROR_CREDENTIALS);
                                return;
                            }
                        } catch (...) {
                            cb(RevokeDeviceResult::ERROR_CREDENTIALS);
                            return;
                        }
                        this_->info_->contacts->foundAccountDevice(crt);
                        // add to CRL cache
                        this_->certStore().pinRevocationList(a.id.second->getId().toString(), a.revoked);
                        this_->certStore().loadRevocations(*a.id.second);

                        // Announce CRL immediately
                        auto h = a.id.second->getId();
                        auto crlVal = std::make_shared<dht::Value>(*a.revoked);
                        crlVal->priority = 1; // CRLs are not urgent
                        this_->dht_->put(h, crlVal, dht::DoneCallback {}, {}, true);

                        this_->info_->contacts->removeAccountDevice(crt->getLongId());
                        cb(RevokeDeviceResult::SUCCESS);
                        this_->syncDevices();
                    });
    return false;
}

bool
ArchiveAccountManager::exportArchive(const std::string& destinationPath,
                                     std::string_view scheme,
                                     const std::string& password)
{
    return exportArchive(destinationPath, scheme, password, scheme, password);
}

bool
ArchiveAccountManager::exportArchive(const std::string& destinationPath,
                                     std::string_view inputScheme,
                                     const std::string& inputPassword,
                                     std::string_view outputScheme,
                                     const std::string& outputPassword)
{
    std::lock_guard lock(archiveMutex_);
    try {
        const auto livePath = fileutils::getFullPath(path_, archivePath_);
        const auto destination = std::filesystem::path(destinationPath);
        std::error_code equivalentError;
        if (std::filesystem::equivalent(livePath, destination, equivalentError) && !equivalentError) {
            JAMI_ERROR("[Auth] Refusing to export over the live account archive");
            return false;
        }
        std::error_code liveError;
        std::error_code destinationError;
        const auto normalizedLive = std::filesystem::weakly_canonical(livePath, liveError);
        const auto normalizedDestination = std::filesystem::weakly_canonical(destination, destinationError);
        if (!liveError && !destinationError && normalizedLive == normalizedDestination) {
            JAMI_ERROR("[Auth] Refusing to export over the live account archive");
            return false;
        }

        // Build one current snapshot while holding the same archive
        // transaction used by password changes and other archive updates.
        // Only the destination is written: export never re-keys or otherwise
        // mutates the live archive.
        AccountArchive archive = readArchiveUnlocked(inputScheme, inputPassword);
        updateArchive(archive);
        return archive.save(destination, outputScheme, outputPassword);
    } catch (const std::runtime_error& ex) {
        JAMI_ERROR("[Auth] Unable to export archive: {}", ex.what());
        return false;
    } catch (...) {
        JAMI_ERROR("[Auth] Unable to export archive: Unable to read archive");
        return false;
    }
}

bool
ArchiveAccountManager::isPasswordValid(const std::string& password)
{
    try {
        readArchive(fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD, password);
        return true;
    } catch (...) {
        return false;
    }
}

void
ArchiveAccountManager::registerName(const std::string& name,
                                    std::string_view scheme,
                                    const std::string& password,
                                    RegistrationCallback cb)
{
    std::string signedName;
    auto nameLowercase {name};
    std::transform(nameLowercase.begin(), nameLowercase.end(), nameLowercase.begin(), ::tolower);
    std::string publickey;
    std::string accountId;
    std::string ethAccount;

    try {
        auto archive = readArchive(scheme, password);
        auto privateKey = archive.id.first;
        const auto& pk = privateKey->getPublicKey();
        publickey = pk.toString();
        accountId = pk.getId().toString();
        signedName = base64::encode(privateKey->sign(std::vector<uint8_t>(nameLowercase.begin(), nameLowercase.end())));
        ethAccount = dev::KeyPair(dev::Secret(archive.eth_key)).address().hex();
    } catch (const std::exception& e) {
        // JAMI_ERR("[Auth] Unable to export account: %s", e.what());
        cb(NameDirectory::RegistrationResponse::invalidCredentials, name);
        return;
    }

    nameDir_.get().registerName(accountId, nameLowercase, ethAccount, cb, signedName, publickey);
}

} // namespace jami
