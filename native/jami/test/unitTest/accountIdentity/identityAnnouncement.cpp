/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "jamidht/identity_announcement.h"
#include "jami.h"
#include "configurationmanager_interface.h"
#include "account_const.h"
#include "manager.h"
#include "jamidht/jamiaccount.h"
#include <opendht.h>
#include <opendht/securedht.h>
#include <asio.hpp>
#include <array>
#include <msgpack.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace std::chrono_literals;
using Details = std::map<std::string, std::string>;

static void require(bool condition, const char* message)
{
    if (!condition)
        throw std::runtime_error(message);
}

template<class Predicate>
static void waitFor(Predicate predicate, const char* message, std::chrono::seconds timeout = 30s)
{
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!predicate()) {
        require(std::chrono::steady_clock::now() < deadline, message);
        std::this_thread::sleep_for(25ms);
    }
}

static void policy()
{
    using State = jami::IdentityAnnouncement;
    using Action = State::Action;
    State attempt;
    require(attempt.finish(1, true).action == Action::Ignore, "Future callback was accepted");
    for (unsigned index = 0; index < State::maximumRetries; ++index) {
        const auto next = attempt.finish(index, false);
        require(next.action == Action::Retry && next.attempt == index + 1, "Retry ownership changed");
        require(attempt.finish(index, true).action == Action::Ignore, "Late callback completed another attempt");
    }
    require(attempt.finish(State::maximumRetries, false).action == Action::Exhausted, "Retry bound was not enforced");
    require(attempt.finish(State::maximumRetries, true).action == Action::Ignore, "Exhausted sequence revived");
    State published;
    require(published.finish(0, true).action == Action::Published, "Publication not accepted");
    require(published.finish(0, false).action == Action::Ignore, "Publication restarted retries");
    State retired;
    require(retired.finish(0, false).action == Action::Retry, "Initial retry was refused");
    retired.retire();
    require(retired.finish(1, true).action == Action::Ignore, "Retired publication was accepted");
    require(retired.finish(1, false).action == Action::Ignore, "Retired retry was accepted");
    std::cout << "Identity announcement ownership, duplicate callbacks and retry bound passed\n";
}

// A private loopback relay drops actual OpenDHT put requests while permitting
// discovery. Rejecting storePolicy is not sufficient: OpenDHT may acknowledge
// that UDP request despite refusing the value, so it never tests a failed put.
class PublicationBarrier
{
public:
    explicit PublicationBarrier(unsigned short bootstrapPort)
        : socket_(context_, {asio::ip::address_v4::loopback(), 0})
        , bootstrap_(asio::ip::address_v4::loopback(), bootstrapPort)
    {
        port_ = socket_.local_endpoint().port();
        receive();
        thread_ = std::thread([this] { context_.run(); });
    }
    ~PublicationBarrier() { context_.stop(); if (thread_.joinable()) thread_.join(); }
    unsigned short port() const { return port_; }
    std::atomic_bool allow {false};
    std::atomic_uint dropped {0};
private:
    bool isPublication(size_t size) const
    {
        try {
            auto handle = msgpack::unpack(buffer_.data(), size);
            const auto& object = handle.get();
            if (object.type != msgpack::type::MAP) return false;
            for (uint32_t i = 0; i < object.via.map.size; ++i) {
                const auto& field = object.via.map.ptr[i];
                if (field.key.as<std::string>() == "q")
                    return field.val.as<std::string>() == "put";
            }
        } catch (...) {}
        return false;
    }
    void receive()
    {
        socket_.async_receive_from(asio::buffer(buffer_), sender_,
            [this](const std::error_code& error, size_t size) {
                if (error) return;
                auto destination = bootstrap_;
                bool forward = true;
                if (sender_ == bootstrap_) destination = client_;
                else {
                    client_ = sender_;
                    if (!allow.load() && isPublication(size)) {
                        ++dropped;
                        forward = false;
                    }
                }
                if (forward && destination.port()) {
                    auto packet = std::make_shared<std::vector<char>>(buffer_.begin(), buffer_.begin() + size);
                    socket_.async_send_to(asio::buffer(*packet), destination,
                        [packet](const std::error_code&, size_t) {});
                }
                receive();
            });
    }
    asio::io_context context_;
    asio::ip::udp::socket socket_;
    asio::ip::udp::endpoint bootstrap_, client_, sender_;
    std::array<char, 65536> buffer_ {};
    unsigned short port_ {};
    std::thread thread_;
};

static void live(const std::string& mode)
{
    dht::DhtRunner bootstrap;
    dht::DhtRunner::Config config;
    config.dht_config.node_config.network = 0;
    bootstrap.run("127.0.0.1", "::1", "0", config);
    PublicationBarrier barrier(bootstrap.getBoundPort());
    bool initialized = false;
    try {
        require(libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_START_INACTIVE |
            libjami::LIBJAMI_FLAG_CONSOLE_LOG)), "Daemon init failed");
        initialized = true;
        require(libjami::start("jami-sample.yml"), "Daemon start failed");
        Details account {{"Account.type", "RING"}, {"Account.enable", "true"},
            {"Account.hostname", "127.0.0.1:" + std::to_string(barrier.port())},
            {"Account.bootstrapListUrl", ""}, {"Account.proxyEnabled", "false"},
            {"Account.proxyListEnabled", "false"}, {"Account.upnpEnabled", "false"},
            {"TURN.enable", "false"}, {"Account.peerDiscovery", "false"},
            {"Account.accountDiscovery", "false"}, {"Account.accountPublish", "false"},
            {"DHT.PublicInCalls", "false"}};
        const auto id = libjami::addAccount(account);
        require(!id.empty(), "Fixture identity creation failed");
        waitFor([&] { auto value = libjami::getAccountDetails(id);
            return value["Account.username"].size() == 40 &&
                libjami::getVolatileAccountDetails(id)[libjami::Account::ConfProperties::DEVICE_ID].size() == 64; }, "Fixture identity initialization timed out");
        const auto native = jami::Manager::instance().getAccount<jami::JamiAccount>(id);
        require(native && native->accountManager() && native->accountManager()->getInfo(),
                "New account has no certificate owner");
        const auto certificate = native->accountManager()->getInfo()->identity.second;
        require(certificate != nullptr, "New device certificate is missing");
        auto root = certificate;
        while (root->issuer) root = root->issuer;
        dht::crypto::TrustList trust;
        trust.add(*root);
        require(bool(trust.verify(*certificate)), "New device chain is not immediately valid");
        const auto before = libjami::getAccountDetails(id);
        const auto deviceBefore = libjami::getVolatileAccountDetails(id).at(libjami::Account::ConfProperties::DEVICE_ID);
        std::atomic_bool sawFailedCompletion {false};
        jami::IdentityAnnouncement::setRetryHookForTesting(
            [&] { sawFailedCompletion.store(true); });
        libjami::setAccountActive(id, true);
        waitFor([&] { return barrier.dropped.load() > 0; }, "Certificate publication barrier was not exercised");
        const auto announced = [&] {
            return libjami::getVolatileAccountDetails(id)
                [libjami::Account::VolatileProperties::DEVICE_ANNOUNCED] == "true";
        };
        // Open only after the real failed put callback entered the owned retry
        // path, while attempts remain. The hook observes that edge; it does
        // not synthesize a callback or a successful publication.
        waitFor([&] { return sawFailedCompletion.load(); },
                "Certificate publication did not report its failed completion");
        require(!announced(), "Unacknowledged certificate was marked announced");
        std::cout << "Publication wire barrier exercised: " << barrier.dropped.load() << std::endl;
        if (mode == "retire") {
            libjami::removeAccount(id);
            barrier.allow.store(true);
            std::this_thread::sleep_for(10s);
            const auto ids = libjami::getAccountList();
            require(std::find(ids.begin(), ids.end(), id) == ids.end(), "Retired identity was recreated");
        } else {
            if (mode == "replace") libjami::setAccountActive(id, false);
            barrier.allow.store(true);
            if (mode == "replace") libjami::setAccountActive(id, true);
            waitFor(announced, "Account never recovered from the failed identity announcement");
            const auto after = libjami::getAccountDetails(id);
            require(before.at("Account.username") == after.at("Account.username") &&
                    deviceBefore == libjami::getVolatileAccountDetails(id).at(libjami::Account::ConfProperties::DEVICE_ID),
                    "Publication recovery replaced the account or device certificate");
        }
        jami::IdentityAnnouncement::setRetryHookForTesting({});
        libjami::fini(); initialized = false;
        bootstrap.shutdown(); bootstrap.join();
        std::cout << (mode == "retire" ? "Retired announcement cannot revive its account\n"
            : mode == "replace" ? "A replacement DHT run owns its own publication\n"
            : "Transient certificate failure recovered through an acknowledged publication\n");
    } catch (...) {
        jami::IdentityAnnouncement::setRetryHookForTesting({});
        if (initialized) libjami::fini();
        bootstrap.shutdown(); bootstrap.join();
        throw;
    }
}

int main(int argc, char** argv)
{
    const std::string mode = argc == 2 ? argv[1] : "retry";
    try {
        policy();
        if (mode == "retry" || mode == "retire" || mode == "replace")
            live(mode);
        else
            require(mode == "policy", "Expected policy, retry, retire or replace mode");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
