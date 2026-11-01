/*
 * Copyright (C) 2004-2026 Savoir-faire Linux Inc.
 * Copyright (C) 2026 Doorlight contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "archive_account_manager.h"
#include "device_pairing_wire.h"
#include "device_pairing_commitment.h"
#include "accountarchive.h"
#include "base64.h"
#include "fileutils.h"
#include "manager.h"
#include "jami/account_const.h"
#include "client/jami_signal.h"
#include <gnutls/crypto.h>
#include <dhtnet/certstore.h>
#include <opendht/thread_pool.h>
#include <atomic>
#include <array>
#include <cstring>
#include <limits>

namespace jami {
namespace {
constexpr std::string_view pairingScheme = "doorlight-code-v1";
constexpr std::string_view uriPrefix = "jami-auth://";
constexpr std::string_view uriVersion = "/doorlight-v1";
constexpr std::string_view channelPrefix = "auth:";
constexpr size_t maxArchiveBytes = 16 * 1024 * 1024;
constexpr size_t maxWireBytes = maxArchiveBytes + 64 * 1024;
constexpr auto pairingLifetime = std::chrono::minutes(5);
enum class PairingState { Handshake, Consent, Snapshot, Code, Archive, Prepared, Final, Done };

uint32_t nextPairingToken()
{
    // Tokens are local operation handles, not secrets. Never reuse one during
    // this process, even if the same account is removed and recreated.
    static std::atomic<uint32_t> next {1};
    auto value = next.load();
    while (value <= static_cast<uint32_t>(std::numeric_limits<int32_t>::max()))
        if (next.compare_exchange_weak(value, value + 1)) return value;
    return 0;
}

bool digits(std::string_view text, size_t count)
{
    return text.size() == count && std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; });
}

std::string freshCode()
{
    // Rejection sampling avoids modulo bias; this is not the daemon's MT RNG.
    uint32_t sample;
    do {
        if (gnutls_rnd(GNUTLS_RND_RANDOM, &sample, sizeof(sample)) != 0)
            throw std::runtime_error("Pairing randomness unavailable");
    } while (sample >= 4200000000u);
    return fmt::format("{:08}", sample % 100000000u);
}

bool sameCode(std::string_view expected, std::string_view supplied)
{
    if (!digits(expected, 8) || !digits(supplied, 8)) return false;
    unsigned difference = 0;
    for (size_t i = 0; i < 8; ++i) difference |= static_cast<unsigned>(expected[i] ^ supplied[i]);
    return difference == 0;
}

std::string proofText(std::string_view temporaryDevice, uint32_t operation,
                      std::string_view account, std::string_view newDevice)
{
    return fmt::format("doorlight-link-v1:{}:{}:{}:{}", temporaryDevice, operation, account, newDevice);
}

void stripLocalCredentials(AccountArchive& archive)
{
    using namespace libjami::Account::ConfProperties;
    for (auto key : {ARCHIVE_PASSWORD, ARCHIVE_PASSWORD_SCHEME, ARCHIVE_PATH, ARCHIVE_URL,
                     TLS::PASSWORD, TLS::PRIVATE_KEY_FILE, TLS::CERTIFICATE_FILE, TLS::CA_LIST_FILE})
        archive.config.erase(key);
}
} // namespace

using AuthMsg = pairing::Message;

struct ArchiveAccountManager::DeviceContextBase {
    PairingState state {PairingState::Handshake};
    std::shared_ptr<dhtnet::ChannelSocket> channel;
    uint32_t operation {0};
};

struct ArchiveAccountManager::LinkDeviceContext : DeviceContextBase {
    dht::crypto::Identity temporaryIdentity;
    std::shared_ptr<dht::DhtRunner> dht;
    std::unique_ptr<dhtnet::ConnectionManager> connections;
    bool channelClaimed {false};
    bool uriIssued {false};
    unsigned attempts {0};
    std::string commitment;
    std::string enteredCode;
};

struct ArchiveAccountManager::AddDeviceContext : DeviceContextBase {
    unsigned attempts {0};
    std::string opening;
};

bool ArchiveAccountManager::ownsPairing(const std::shared_ptr<AuthContext>& ctx) const
{
    if (std::atomic_load(&authCtx_) != ctx || ctx->terminal || ctx->canceled ||
        std::chrono::steady_clock::now() >= ctx->deadline) return false;
    auto account = Manager::instance().getAccount<JamiAccount>(ctx->accountId);
    // Account ID reuse or disabling/replacing a source cannot revive a callback.
    return account && account->ownsPairingManager(this, static_cast<bool>(ctx->linkDevCtx));
}

bool ArchiveAccountManager::hasPendingDeviceLink() const
{
    // linkDevCtx is assigned before the context is atomically published and is
    // never replaced. Do not take ctx->mutex under JamiAccount's config mutex.
    const auto ctx = std::atomic_load(&authCtx_);
    return ctx && static_cast<bool>(ctx->linkDevCtx);
}

bool ArchiveAccountManager::claimPairing(const std::shared_ptr<AuthContext>& ctx)
{
    std::shared_ptr<AuthContext> empty;
    ctx->deadline = std::chrono::steady_clock::now() + pairingLifetime;
    return std::atomic_compare_exchange_strong(&authCtx_, &empty, ctx);
}

void ArchiveAccountManager::finishPairing(const std::shared_ptr<AuthContext>& ctx, const std::string& error)
{
    std::lock_guard lock(ctx->mutex);
    if (ctx->terminal) return;
    ctx->terminal = true;
    ctx->pairingCode.clear();
    ctx->immutableArchive.clear();
    if (ctx->addDeviceCtx) ctx->addDeviceCtx->opening.clear();
    if (ctx->linkDevCtx) ctx->linkDevCtx->enteredCode.clear();
    if (ctx->timeout) ctx->timeout->cancel();
    auto expected = ctx;
    std::atomic_compare_exchange_strong(&authCtx_, &expected, std::shared_ptr<AuthContext>());
    auto channel = ctx->linkDevCtx ? ctx->linkDevCtx->channel :
                   ctx->addDeviceCtx ? ctx->addDeviceCtx->channel : nullptr;
    if (ctx->linkDevCtx) ctx->linkDevCtx->channel.reset();
    if (ctx->addDeviceCtx) ctx->addDeviceCtx->channel.reset();
    std::map<std::string, std::string> detail {{"error", error}, {"token", std::to_string(ctx->token)},
        {"peer_id", ctx->expectedPeerAccount}, {"peer_device", ctx->expectedPeerDevice},
        {"device_id", ctx->preparedDeviceId}};
    if (ctx->linkDevCtx) {
        if (info_ && error.empty()) detail["device_id"] = info_->deviceId;
        emitSignal<libjami::ConfigurationSignal::DeviceAuthStateChanged>(ctx->accountId,
            static_cast<uint8_t>(DeviceAuthState::DONE), detail);
    } else {
        emitSignal<libjami::ConfigurationSignal::AddDeviceStateChanged>(ctx->accountId, ctx->token,
            static_cast<uint8_t>(DeviceAuthState::DONE), detail);
    }
    // Do not destroy a connection manager on its own transport callback stack.
    dht::ThreadPool::io().run([ctx, channel] {
        // ChannelSocket invokes receive and shutdown callbacks under its own
        // mutex. Shutdown must therefore be outside both callback and ctx locks.
        if (channel) channel->shutdown();
        std::unique_ptr<dhtnet::ConnectionManager> connections;
        std::shared_ptr<dht::DhtRunner> dht;
        {
            std::lock_guard lock(ctx->mutex);
            if (ctx->linkDevCtx) {
                connections = std::move(ctx->linkDevCtx->connections);
                dht = ctx->linkDevCtx->dht;
            }
        }
        connections.reset();
        if (dht) dht->shutdown({});
    });
}

void ArchiveAccountManager::armPairingDeadline(const std::shared_ptr<AuthContext>& ctx)
{
    ctx->timeout = std::make_unique<asio::steady_timer>(*Manager::instance().ioContext());
    ctx->timeout->expires_at(ctx->deadline);
    ctx->timeout->async_wait([w = weak(), c = std::weak_ptr(ctx)](const std::error_code& error) {
        if (error) return;
        if (auto self = w.lock()) if (auto ctx = c.lock()) {
            std::lock_guard lock(ctx->mutex);
            if (std::chrono::steady_clock::now() >= ctx->deadline) self->finishPairing(ctx, "timeout");
        }
    });
}

bool ArchiveAccountManager::provideAccountAuthentication(const std::string& code, const std::string& scheme)
{
    auto ctx = std::atomic_load(&authCtx_);
    if (!ctx) return false;
    std::lock_guard lock(ctx->mutex);
    if (!ownsPairing(ctx) || !ctx->linkDevCtx || scheme != pairingScheme || !digits(code, 8) ||
        ctx->linkDevCtx->state != PairingState::Code || ctx->linkDevCtx->commitment.size() != 64) return false;
    auto& destination = *ctx->linkDevCtx;
    if (++destination.attempts > 3) { finishPairing(ctx, "auth_error"); return false; }
    // This code travels only inside the existing certificate-bound confidential
    // channel. The source's commitment is already frozen; an archive is not
    // accepted until its previously withheld opening verifies this exact code.
    destination.enteredCode = code;
    destination.state = PairingState::Archive;
    AuthMsg message;
    message.payload["code"] = code;
    if (!message.send(ctx->linkDevCtx->channel)) {
        finishPairing(ctx, "network");
        return false;
    }
    return true;
}

bool ArchiveAccountManager::confirmAddDevice(uint32_t)
{
    // This legacy entry point cannot authorize reading a device-sealed archive.
    return false;
}

bool ArchiveAccountManager::cancelAddDevice(uint32_t token)
{
    auto ctx = std::atomic_load(&authCtx_);
    if (!ctx) return false;
    std::lock_guard lock(ctx->mutex);
    if (ctx->token != token || ctx->terminal) return false;
    ctx->canceled = true;
    finishPairing(ctx, "canceled");
    return true;
}
int32_t ArchiveAccountManager::addDevice(const std::string& uri, std::string_view,
                                        AuthChannelHandler* handler)
{
    const auto expectedSize = uriPrefix.size() + 64 + 1 + 6 + uriVersion.size();
    if (!handler || !info_ || uri.size() != expectedSize ||
        uri.compare(0, uriPrefix.size(), uriPrefix) != 0 ||
        uri.compare(uri.size() - uriVersion.size(), uriVersion.size(), uriVersion) != 0)
        return static_cast<int32_t>(AddDeviceError::INVALID_URI);
    const auto peer = uri.substr(uriPrefix.size(), 64);
    const auto operation = uri.substr(uriPrefix.size() + 65, 6);
    if (uri[uriPrefix.size() + 64] != '/' || !digits(operation, 6) || operation.front() == '0' ||
        !std::all_of(peer.begin(), peer.end(), [](char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        })) return static_cast<int32_t>(AddDeviceError::INVALID_URI);
    auto ctx = std::make_shared<AuthContext>();
    ctx->accountId = accountId_;
    ctx->expectedPeerDevice = peer;
    ctx->expectedPeerAccount = info_->accountId;
    ctx->token = nextPairingToken();
    if (!ctx->token) return static_cast<int32_t>(AddDeviceError::GENERIC);
    ctx->addDeviceCtx = std::make_shared<AddDeviceContext>();
    ctx->addDeviceCtx->operation = static_cast<uint32_t>(std::stoul(operation));
    if (!claimPairing(ctx)) return static_cast<int32_t>(AddDeviceError::ALREADY_LINKING);
    if (!ownsPairing(ctx)) {
        finishPairing(ctx, "account_changed");
        return static_cast<int32_t>(AddDeviceError::GENERIC);
    }
    armPairingDeadline(ctx);
    emitSignal<libjami::ConfigurationSignal::AddDeviceStateChanged>(accountId_, ctx->token,
        static_cast<uint8_t>(DeviceAuthState::CONNECTING), std::map<std::string, std::string> {});
    handler->connect(dht::PkId(peer), fmt::format("{}{}", channelPrefix, operation),
        [w = weak(), ctx](std::shared_ptr<dhtnet::ChannelSocket> socket, const dht::PkId&) {
            if (auto self = w.lock()) {
                std::lock_guard lock(ctx->mutex);
                if (!self->ownsPairing(ctx)) { if (socket) socket->shutdown(); return; }
                if (!socket || !self->doAddDevice(pairingScheme, ctx, socket))
                    self->finishPairing(ctx, "network");
            } else if (socket) socket->shutdown();
        });
    return static_cast<int32_t>(ctx->token);
}

bool ArchiveAccountManager::doAddDevice(std::string_view, const std::shared_ptr<AuthContext>& ctx,
                                       std::shared_ptr<dhtnet::ChannelSocket> channel)
{
    const auto certificate = channel->peerCertificate();
    if (!ownsPairing(ctx) || !certificate || !certificate->issuer ||
        certificate->getLongId().toString() != ctx->expectedPeerDevice) return false;
    ctx->addDeviceCtx->channel = channel;
    channel->onShutdown([w = weak(), c = std::weak_ptr(ctx)](const std::error_code&) {
        if (auto self = w.lock()) if (auto ctx = c.lock()) self->finishPairing(ctx, "network");
    });
    channel->setOnRecv(AuthMsg::reader([w = weak(), c = std::weak_ptr(ctx)](AuthMsg&& message) {
        auto self = w.lock(); auto ctx = c.lock();
        if (!self || !ctx) return false;
        std::lock_guard lock(ctx->mutex);
        if (!self->ownsPairing(ctx)) { self->finishPairing(ctx, "account_changed"); return false; }
        auto& source = *ctx->addDeviceCtx;
        if (message.schemeId != 1) { self->finishPairing(ctx, "unsupported"); return false; }
        if (source.state == PairingState::Handshake && message.only({})) {
            source.state = PairingState::Consent;
            emitSignal<libjami::ConfigurationSignal::AddDeviceStateChanged>(ctx->accountId, ctx->token,
                static_cast<uint8_t>(DeviceAuthState::AUTHENTICATING),
                std::map<std::string, std::string> {{"auth_scheme", std::string(pairingScheme)},
                    {"peer_device", ctx->expectedPeerDevice}});
            return true;
        }
        if (source.state == PairingState::Code && message.only({"code"})) {
            ++source.attempts;
            if (!sameCode(ctx->pairingCode, message.at("code"))) {
                if (source.attempts >= 3) { self->finishPairing(ctx, "auth_error"); return false; }
                AuthMsg retry;
                retry.payload["retry"] = "true";
                if (!retry.send(source.channel)) { self->finishPairing(ctx, "network"); return false; }
                return true;
            }
            source.state = PairingState::Archive;
            ctx->pairingCode.clear();
            AuthMsg archive;
            archive.payload["accData"] = std::move(ctx->immutableArchive);
            archive.payload["opening"] = std::move(source.opening);
            if (!archive.send(source.channel)) { self->finishPairing(ctx, "network"); return false; }
            emitSignal<libjami::ConfigurationSignal::AddDeviceStateChanged>(ctx->accountId, ctx->token,
                static_cast<uint8_t>(DeviceAuthState::IN_PROGRESS), std::map<std::string, std::string> {});
            return true;
        }
        if (source.state == PairingState::Archive && message.only({"preparedDevice", "proof"})) {
            try {
                auto device = std::make_shared<dht::crypto::Certificate>(base64::decode(message.at("preparedDevice")));
                const auto deviceId = device->getLongId().toString();
                if (!self->info_ || !device->issuer || device->isCA() ||
                    device->issuer->getId().toString() != ctx->expectedPeerAccount ||
                    deviceId == self->info_->deviceId || deviceId == ctx->expectedPeerDevice)
                    throw std::runtime_error("Invalid paired device");
                dht::crypto::TrustList trust;
                trust.add(*self->info_->identity.second->issuer);
                if (!trust.verify(*device)) throw std::runtime_error("Invalid paired certificate");
                auto proof = base64::decode(message.at("proof"));
                auto text = proofText(ctx->expectedPeerDevice, source.operation, ctx->expectedPeerAccount, deviceId);
                if (!device->getPublicKey().checkSignature(reinterpret_cast<const uint8_t*>(text.data()),
                        text.size(), proof.data(), proof.size())) throw std::runtime_error("Invalid pairing proof");
                AuthMsg done;
                done.payload["stateMsg"] = "DONE";
                if (!done.send(source.channel)) throw std::runtime_error("Pairing acknowledgement failed");
                ctx->preparedDeviceId = deviceId;
                source.state = PairingState::Final;
                return true;
            } catch (...) { self->finishPairing(ctx, "invalid_peer"); return false; }
        }
        if (source.state == PairingState::Final && message.only({"stateMsg"}) && message.at("stateMsg") == "ACK") {
            source.state = PairingState::Done;
            self->finishPairing(ctx, "");
            return false;
        }
        self->finishPairing(ctx, "invalid_state");
        return false;
    }));
    return true;
}

std::string ArchiveAccountManager::confirmAddDeviceWithCode(uint32_t token, const std::string& localArchiveSecret)
{
    auto ctx = std::atomic_load(&authCtx_);
    if (!ctx || localArchiveSecret.empty() || localArchiveSecret.size() > 4096) return {};
    {
        std::lock_guard lock(ctx->mutex);
        if (!ownsPairing(ctx) || ctx->token != token || !ctx->addDeviceCtx ||
            ctx->addDeviceCtx->state != PairingState::Consent) return {};
        ctx->addDeviceCtx->state = PairingState::Snapshot;
    }
    try {
        std::string snapshot;
        {
            std::lock_guard archiveLock(archiveMutex_);
            auto archive = readArchiveUnlocked(fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD, localArchiveSecret);
            if (!archive.id.second || archive.id.second->getId().toString() != ctx->expectedPeerAccount)
                throw std::runtime_error("Source archive changed");
            updateArchive(archive);
            stripLocalCredentials(archive);
            snapshot = archive.serialize();
        }
        if (snapshot.empty() || snapshot.size() > maxArchiveBytes) throw std::runtime_error("Archive exceeds pairing bound");
        auto code = freshCode();
        std::lock_guard lock(ctx->mutex);
        if (!ownsPairing(ctx) || ctx->addDeviceCtx->state != PairingState::Snapshot) return {};
        ctx->immutableArchive = std::move(snapshot);
        ctx->pairingCode = code;
        ctx->addDeviceCtx->state = PairingState::Code;
        AuthMsg approved;
        approved.payload["authScheme"] = std::string(pairingScheme);
        ctx->addDeviceCtx->opening = pairing::freshOpening();
        approved.payload["codeCommitment"] = pairing::codeCommitment(code, ctx->addDeviceCtx->opening, info_->deviceId,
            ctx->expectedPeerDevice, ctx->addDeviceCtx->operation);
        if (!approved.send(ctx->addDeviceCtx->channel)) { finishPairing(ctx, "network"); return {}; }
        return code;
    } catch (...) { finishPairing(ctx, "archive_error"); return {}; }
}
void ArchiveAccountManager::startLoadArchiveFromDevice(const std::shared_ptr<AuthContext>& ctx)
{
    ctx->linkDevCtx = std::make_shared<LinkDeviceContext>();
    if (!ctx->credentials->pairingConnection || ctx->credentials->password.empty() ||
        ctx->credentials->password_scheme != fileutils::ARCHIVE_AUTH_SCHEME_PASSWORD || !claimPairing(ctx)) {
        ctx->onFailure(AuthError::INVALID_ARGUMENTS, "Device linking requires local protection and network policy");
        return;
    }
    armPairingDeadline(ctx);
    dht::ThreadPool::computation().run([ctx, w = weak()] {
        auto self = w.lock();
        if (!self) return;
        try {
            auto ca = dht::crypto::generateEcIdentity("Jami Temporary CA");
            auto user = dht::crypto::generateIdentity("Jami Temporary User", ca, 4096, true);
            auto temporary = dht::crypto::generateIdentity("Jami Temporary device", user);
            std::lock_guard lock(ctx->mutex);
            if (!self->ownsPairing(ctx)) return;
            auto& destination = *ctx->linkDevCtx;
            destination.temporaryIdentity = temporary;
            auto config = ctx->credentials->pairingConnection;
            config->id = temporary;
            config->ioContext = Manager::instance().ioContext();
            config->factory = Manager::instance().getIceTransportFactory();
            config->rng = std::make_unique<std::mt19937_64>(Manager::instance().getSeededRandomEngine());
            config->legacyMode = dhtnet::LegacyMode::Disabled;
            config->certStore = std::make_shared<dhtnet::tls::CertificateStore>(self->path_ / "pairing", nullptr);
            auto dhtConfig = ctx->credentials->pairingDht;
            dhtConfig.dht_config.id = temporary;
            auto weakContext = std::weak_ptr(ctx);
            dht::DhtRunner::Context dhtContext;
            dhtContext.identityAnnouncedCb = [w, weakContext](bool published) {
                if (!published) return;
                // DHT callbacks must not block on the operation mutex while
                // run/bootstrap is setting up that same DHT runner.
                dht::ThreadPool::io().run([w, weakContext] {
                    auto self = w.lock(); auto ctx = weakContext.lock();
                    if (!self || !ctx) return;
                    std::lock_guard lock(ctx->mutex);
                    if (!self->ownsPairing(ctx) || ctx->linkDevCtx->uriIssued) return;
                    ctx->linkDevCtx->uriIssued = true;
                    // Do not offer a URI while the temporary certificate is
                    // still unavailable to the source's certificate lookup.
                    // Reset once at actual issuance, never on connect/retry.
                    ctx->deadline = std::chrono::steady_clock::now() + pairingLifetime;
                    self->armPairingDeadline(ctx);
                    auto uri = fmt::format("{}{}/{}{}", uriPrefix,
                        ctx->linkDevCtx->temporaryIdentity.second->getLongId(), ctx->token, uriVersion);
                    emitSignal<libjami::ConfigurationSignal::DeviceAuthStateChanged>(ctx->accountId,
                        static_cast<uint8_t>(DeviceAuthState::TOKEN_AVAILABLE),
                        std::map<std::string, std::string> {{"token", uri}, {"operation", std::to_string(ctx->token)},
                            {"auth_scheme", std::string(pairingScheme)}});
                });
            };
            dhtContext.certificateStore = [store = config->certStore](const dht::PkId& id) {
                std::vector<std::shared_ptr<dht::crypto::Certificate>> result;
                if (auto cert = store->getCertificate(id.toString())) result.emplace_back(std::move(cert));
                return result;
            };
            config->dht = destination.dht = std::make_shared<dht::DhtRunner>();
            config->dht->run(0, dhtConfig, std::move(dhtContext));
            for (const auto& bootstrap : ctx->credentials->dhtBootstrap) config->dht->bootstrap(bootstrap);
            destination.connections = std::make_unique<dhtnet::ConnectionManager>(config);
            ctx->token = destination.operation = std::uniform_int_distribution<uint32_t>(100000, 999999)(*config->rng);
            destination.connections->onICERequest([w, weakContext](const DeviceId&) {
                auto self = w.lock(); auto ctx = weakContext.lock();
                if (!self || !ctx) return false;
                std::lock_guard lock(ctx->mutex);
                if (!self->ownsPairing(ctx)) { self->finishPairing(ctx, "account_changed"); return false; }
                return ctx->linkDevCtx->uriIssued && !ctx->linkDevCtx->channelClaimed;
            });
            destination.connections->onChannelRequest([w, weakContext](const std::shared_ptr<dht::crypto::Certificate>& cert,
                                                                        const std::string& name) {
                auto self = w.lock(); auto ctx = weakContext.lock();
                if (!self || !ctx || !cert || !cert->issuer || cert->isCA()) return false;
                std::lock_guard lock(ctx->mutex);
                if (!self->ownsPairing(ctx)) { self->finishPairing(ctx, "account_changed"); return false; }
                if (!ctx->linkDevCtx->uriIssued || ctx->linkDevCtx->channelClaimed ||
                    name != fmt::format("{}{}", channelPrefix, ctx->token)) return false;
                ctx->expectedPeerDevice = cert->getLongId().toString();
                ctx->expectedPeerAccount = cert->issuer->getId().toString();
                ctx->linkDevCtx->channelClaimed = true;
                return true;
            });
            destination.connections->onConnectionReady([w, weakContext](const DeviceId&, const std::string&,
                                                                         const std::shared_ptr<dhtnet::ChannelSocket>& channel) {
                auto self = w.lock(); auto ctx = weakContext.lock();
                if (!self || !ctx) { if (channel) channel->shutdown(); return; }
                std::lock_guard lock(ctx->mutex);
                if (!self->ownsPairing(ctx)) { if (channel) channel->shutdown(); return; }
                auto cert = channel ? channel->peerCertificate() : nullptr;
                if (!cert || !cert->issuer || cert->getLongId().toString() != ctx->expectedPeerDevice ||
                    cert->issuer->getId().toString() != ctx->expectedPeerAccount || ctx->linkDevCtx->channel) {
                    self->finishPairing(ctx, "invalid_peer"); return;
                }
                ctx->linkDevCtx->channel = channel;
                channel->onShutdown([w, weakContext](const std::error_code&) {
                    if (auto self = w.lock()) if (auto ctx = weakContext.lock()) self->finishPairing(ctx, "network");
                });
                channel->setOnRecv(AuthMsg::reader([w, weakContext](AuthMsg&& message) {
                    auto self = w.lock(); auto ctx = weakContext.lock();
                    if (!self || !ctx) return false;
                    std::lock_guard lock(ctx->mutex);
                    if (!self->ownsPairing(ctx)) { self->finishPairing(ctx, "account_changed"); return false; }
                    auto& destination = *ctx->linkDevCtx;
                    if (message.schemeId != 1) { self->finishPairing(ctx, "unsupported"); return false; }
                    const bool challenge = destination.state == PairingState::Handshake &&
                        message.only({"authScheme", "codeCommitment"}) && message.at("authScheme") == pairingScheme &&
                        message.at("codeCommitment").size() == 64 &&
                        std::all_of(message.at("codeCommitment").begin(), message.at("codeCommitment").end(), [](char c) {
                            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                        });
                    const bool retry = destination.state == PairingState::Archive && destination.attempts < 3 &&
                        message.only({"retry"}) && message.at("retry") == "true";
                    if (challenge || retry) {
                        if (challenge) destination.commitment = message.at("codeCommitment");
                        destination.enteredCode.clear();
                        destination.state = PairingState::Code;
                        emitSignal<libjami::ConfigurationSignal::DeviceAuthStateChanged>(ctx->accountId,
                            static_cast<uint8_t>(DeviceAuthState::AUTHENTICATING),
                            std::map<std::string, std::string> {{"auth_scheme", std::string(pairingScheme)},
                                {"peer_id", ctx->expectedPeerAccount}, {"peer_device", ctx->expectedPeerDevice},
                                {"token", std::to_string(ctx->token)}, {"auth_error", retry ? "invalid_code" : ""}});
                        return true;
                    }
                    if (destination.state == PairingState::Archive && message.only({"accData", "opening"})) {
                        try {
                            if (!pairing::verifyOpening(destination.commitment, destination.enteredCode,
                                    message.at("opening"), ctx->expectedPeerDevice,
                                    destination.temporaryIdentity.second->getLongId().toString(), destination.operation))
                                throw std::runtime_error("Pairing source confirmation failed");
                            destination.enteredCode.clear();
                            auto archive = AccountArchive(std::string_view(message.at("accData")));
                            if (!archive.id.first || !archive.id.second || !archive.id.second->isCA() ||
                                archive.id.second->getId().toString() != ctx->expectedPeerAccount ||
                                archive.id.first->getPublicKey().getId() != archive.id.second->getId())
                                throw std::runtime_error("Archive does not match authenticated source");
                            dht::crypto::TrustList trust;
                            trust.add(*archive.id.second);
                            if (!trust.verify(*destination.channel->peerCertificate()))
                                throw std::runtime_error("Source certificate does not match archive");
                            stripLocalCredentials(archive);
                            archive.config[libjami::Account::ConfProperties::ENABLED] = "false";
                            self->onArchiveLoaded(*ctx, std::move(archive), true);
                            if (!self->ownsPairing(ctx) || !self->info_ ||
                                self->info_->accountId != ctx->expectedPeerAccount ||
                                self->info_->deviceId == ctx->expectedPeerDevice ||
                                self->info_->deviceId == destination.temporaryIdentity.second->getLongId().toString())
                                throw std::runtime_error("Prepared identity mismatch");
                            destination.state = PairingState::Prepared;
                            ctx->preparedDeviceId = self->info_->deviceId;
                            emitSignal<libjami::ConfigurationSignal::DeviceAuthStateChanged>(ctx->accountId,
                                static_cast<uint8_t>(DeviceAuthState::IN_PROGRESS),
                                std::map<std::string, std::string> {{"prepared", "true"},
                                    {"peer_id", ctx->expectedPeerAccount}, {"peer_device", ctx->expectedPeerDevice},
                                    {"device_id", self->info_->deviceId}, {"token", std::to_string(ctx->token)}});
                            return true;
                        } catch (...) { self->finishPairing(ctx, "archive_error"); return false; }
                    }
                    if (destination.state == PairingState::Final && message.only({"stateMsg"}) && message.at("stateMsg") == "DONE") {
                        AuthMsg acknowledgement;
                        acknowledgement.payload["stateMsg"] = "ACK";
                        if (!acknowledgement.send(destination.channel)) { self->finishPairing(ctx, "network"); return false; }
                        destination.state = PairingState::Done;
                        self->finishPairing(ctx, "");
                        return false;
                    }
                    self->finishPairing(ctx, "invalid_state");
                    return false;
                }));
                AuthMsg hello;
                if (!hello.send(channel)) self->finishPairing(ctx, "network");
            });
            destination.connections->dhtStarted();
        } catch (...) { self->finishPairing(ctx, "network"); }
    });
}

bool ArchiveAccountManager::completeDeviceLinkPreparation(uint32_t token)
{
    auto ctx = std::atomic_load(&authCtx_);
    if (!ctx) return false;
    std::lock_guard lock(ctx->mutex);
    if (!ownsPairing(ctx) || token != ctx->token || !ctx->linkDevCtx || !info_ ||
        ctx->linkDevCtx->state != PairingState::Prepared || info_->accountId != ctx->expectedPeerAccount) return false;
    auto config = onExportConfig_();
    if (config[libjami::Account::ConfProperties::ENABLED] != "false") return false;
    AuthMsg prepared;
    prepared.payload["preparedDevice"] = base64::encode(info_->identity.second->getPacked());
    auto text = proofText(ctx->linkDevCtx->temporaryIdentity.second->getLongId().toString(),
                          ctx->token, info_->accountId, info_->deviceId);
    prepared.payload["proof"] = base64::encode(info_->identity.first->sign(text));
    ctx->linkDevCtx->state = PairingState::Final;
    if (!prepared.send(ctx->linkDevCtx->channel)) { finishPairing(ctx, "network"); return false; }
    return true;
}
} // namespace jami
