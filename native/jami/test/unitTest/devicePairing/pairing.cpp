/* Copyright (C) 2026 Doorlight contributors
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "jami.h"
#include "configurationmanager_interface.h"
#include "manager.h"
#include "jamidht/jamiaccount.h"
#include <atomic>
#include <chrono>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

using namespace std::chrono_literals;
using Details = std::map<std::string, std::string>;
struct Event { int state; Details details; };
struct Events {
    std::mutex mutex;
    std::map<std::string, std::vector<Event>> source, destination;
    Details find(const std::string& id, bool fromSource, int state, unsigned occurrence = 1) {
        std::lock_guard lock(mutex);
        auto& events = fromSource ? source[id] : destination[id];
        for (auto& event : events) if (event.state == state && --occurrence == 0) return event.details;
        return {};
    }
};
static void require(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }
static void waitFor(std::function<bool()> ready, const char* stage, std::chrono::seconds limit = 90s) {
    auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline) {
        if (ready()) return;
        std::this_thread::sleep_for(50ms);
    }
    throw std::runtime_error(std::string("Pairing timeout at ") + stage);
}
int main(int argc, char** argv)
{
    const std::string mode = argc == 2 ? argv[1] : "success";
    auto events = std::make_shared<Events>();
    auto retiredTransport = std::make_shared<std::atomic_bool>(false);
    bool initialized = false;
    try {
        require(libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_START_INACTIVE |
            libjami::LIBJAMI_FLAG_CONSOLE_LOG)), "Daemon init failed");
        initialized = true;
        require(libjami::start("jami-sample.yml"), "Daemon start failed");
        std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> callbacks;
        callbacks.insert(libjami::exportable_callback<libjami::ConfigurationSignal::DeviceAuthStateChanged>(
            [events](const std::string& id, int state, const Details& details) {
                std::lock_guard lock(events->mutex);
                events->destination[id].push_back({state, details});
            }));
        callbacks.insert(libjami::exportable_callback<libjami::ConfigurationSignal::AddDeviceStateChanged>(
            [events, mode, retiredTransport](const std::string& id, uint32_t, int state, const Details& details) {
                {
                    std::lock_guard lock(events->mutex);
                    events->source[id].push_back({state, details});
                }
                // This signal runs synchronously before handler->connect. It
                // deterministically retires the borrowed handler/transport at
                // the old use-after-free boundary, without scheduler timing.
                if (mode == "transport-retired" && state == 2 && !retiredTransport->exchange(true)) {
                    if (auto account = jami::Manager::instance().getAccount<jami::JamiAccount>(id))
                        account->shutdownConnections();
                }
            }));
        libjami::registerSignalHandlers(callbacks);
        const std::string sourceSecret = "fixture-source-installation-secret";
        const std::string destinationSecret = "fixture-destination-installation-secret";
        Details policy {{"Account.type", "RING"}, {"Account.hostname", "127.0.0.1:4222"},
            {"Account.bootstrapListUrl", ""}, {"Account.proxyEnabled", "false"},
            {"Account.proxyListEnabled", "false"}, {"Account.upnpEnabled", "false"},
            {"TURN.enable", "false"}, {"Account.peerDiscovery", "false"},
            {"Account.accountDiscovery", "false"}, {"Account.accountPublish", "false"},
            {"DHT.PublicInCalls", "false"}, {"Account.enable", "true"},
            {"Account.archivePassword", sourceSecret}};
        const auto source = libjami::addAccount(policy);
        require(!source.empty(), "Source creation failed");
        waitFor([&] { return libjami::getAccountDetails(source)["Account.username"].size() == 40; }, "source identity");
        libjami::setAccountActive(source, true);
        waitFor([&] { return libjami::getVolatileAccountDetails(source)["Account.registrationStatus"] == "REGISTERED"; },
                "source registration");
        const auto sourceDetails = libjami::getAccountDetails(source);
        const auto sourceDevice = libjami::getVolatileAccountDetails(source).at("Account.deviceID");
        require(sourceDevice.size() == 64, "Source device fingerprint is unavailable");
        policy["Account.enable"] = "false";
        policy["Account.archiveURL"] = "jami-auth";
        policy["Account.archivePassword"] = destinationSecret;
        const auto destination = libjami::addAccount(policy);
        require(!destination.empty() && destination != source, "Destination creation failed");
        Details offer;
        waitFor([&] { offer = events->find(destination, false, 1); return offer.count("token"); }, "destination URI");
        const auto destinationOperation = static_cast<uint32_t>(std::stoul(offer.at("operation")));
        require(!libjami::completeDeviceLinkPreparation(destination, destinationOperation), "Premature preparation accepted");
        if (mode == "expiry" || mode == "cancel") {
            auto observed = std::chrono::steady_clock::now();
            if (mode == "cancel") {
                require(!libjami::cancelAddDevice(destination, destinationOperation + 1), "Wrong destination operation canceled");
                require(libjami::cancelAddDevice(destination, destinationOperation), "Waiting operation did not cancel");
            }
            Details done;
            waitFor([&] { done = events->find(destination, false, 5); return done.count("error"); },
                    "waiting operation termination", mode == "expiry" ? 310s : 10s);
            require(done["error"] == (mode == "expiry" ? "timeout" : "canceled"), "Wrong waiting terminal result");
            if (mode == "expiry") require(std::chrono::steady_clock::now() - observed >= 299s,
                                          "Pairing expired before its issuance lifetime");
            require(!libjami::cancelAddDevice(destination, destinationOperation), "Terminated operation remained live");
            require(libjami::getAccountDetails(destination)["Account.username"].empty(), "Waiting operation adopted an identity");
            require(libjami::getAccountDetails(destination)["Account.enable"] == "false", "Waiting destination enabled");
            libjami::unregisterSignalHandlers(); libjami::fini();
            std::cout << "Waiting pairing " << mode << " passed\n";
            return 0;
        }
        auto legacy = offer.at("token"); legacy.resize(legacy.size() - std::string("/doorlight-v1").size());
        require(libjami::addDevice(source, legacy) < 0, "Legacy password flow accepted");
        const auto operation = libjami::addDevice(source, offer.at("token"));
        require(operation > 0, "Source pairing did not start");
        if (mode == "transport-retired") {
            require(retiredTransport->load(), "Transport was not retired during admission");
            require(libjami::addDevice(source, offer.at("token")) < 0,
                    "Retired transport admitted another operation");
            libjami::cancelAddDevice(source, operation);
            Details done;
            waitFor([&] { done = events->find(source, true, 5); return done.count("error"); },
                    "retired transport termination", 10s);
            require(!done["error"].empty(), "Retired transport claimed successful pairing");
            require(libjami::isPasswordValid(source, sourceSecret), "Transport retirement changed source protection");
            require(libjami::getAccountDetails(source)["Account.username"] == sourceDetails.at("Account.username"),
                    "Transport retirement changed the source identity");
            require(libjami::getAccountDetails(destination)["Account.username"].empty(),
                    "Transport retirement imported an identity without consent");
            require(libjami::getAccountDetails(destination)["Account.enable"] == "false",
                    "Transport retirement activated the destination");
            libjami::cancelAddDevice(destination, destinationOperation);
            libjami::unregisterSignalHandlers(); libjami::fini();
            std::cout << "Pairing admission survives synchronous transport retirement without adopting an identity\n";
            return 0;
        }
        waitFor([&] { return !events->find(source, true, 3).empty(); }, "source consent");
        require(!libjami::confirmAddDevice(source, operation), "Legacy confirmation accepted");
        require(libjami::confirmAddDeviceWithCode(source, operation + 1, sourceSecret).empty(), "Foreign operation accepted");
        const auto code = libjami::confirmAddDeviceWithCode(source, operation, sourceSecret);
        require(code.size() == 8, "Eight-digit code was not issued");
        require(libjami::isPasswordValid(source, sourceSecret), "Source archive protection changed");
        require(!libjami::isPasswordValid(source, code), "Pairing code became source archive password");
        waitFor([&] { return !events->find(destination, false, 3).empty(); }, "destination code prompt");
        require(!libjami::provideAccountAuthentication(destination, sourceSecret, "password"), "Installation password fallback accepted");
        if (mode == "source-disabled") {
            libjami::setAccountActive(source, false);
            libjami::provideAccountAuthentication(destination, code, "doorlight-code-v1");
            Details destinationDone;
            waitFor([&] { destinationDone = events->find(destination, false, 5); return destinationDone.count("error"); }, "disabled source refusal");
            require(!destinationDone["error"].empty(), "Disabled source completed pairing");
            require(libjami::getAccountDetails(destination)["Account.username"].empty(), "Disabled source imported an identity");
            require(libjami::getAccountDetails(destination)["Account.enable"] == "false", "Disabled source activated destination");
            require(libjami::isPasswordValid(source, sourceSecret), "Disabling source changed archive protection");
            libjami::unregisterSignalHandlers(); libjami::fini();
            std::cout << "Disabled source pairing ownership passed\n";
            return 0;
        }
        auto incorrect = code; incorrect[0] = code[0] == '0' ? '1' : '0';
        if (mode == "attempts") {
            for (unsigned attempt = 0; attempt < 3; ++attempt) {
                require(libjami::provideAccountAuthentication(destination, incorrect, "doorlight-code-v1"), "Code attempt was not issued");
                if (attempt < 2) waitFor([&] { return !events->find(destination, false, 3, attempt + 2).empty(); }, "bounded code retry");
            }
            Details destinationDone, sourceDone;
            waitFor([&] { destinationDone = events->find(destination, false, 5); return destinationDone.count("error"); }, "third-attempt refusal");
            waitFor([&] { sourceDone = events->find(source, true, 5); return sourceDone.count("error"); }, "source third-attempt refusal");
            require(!destinationDone["error"].empty() && sourceDone["error"] == "auth_error", "Wrong-code limit did not fail closed");
            require(!libjami::provideAccountAuthentication(destination, code, "doorlight-code-v1"), "Fourth code attempt accepted");
            require(libjami::getAccountDetails(destination)["Account.username"].empty(), "Wrong code imported an identity");
            require(libjami::isPasswordValid(source, sourceSecret), "Failed attempts changed the source archive");
            libjami::unregisterSignalHandlers(); libjami::fini();
            std::cout << "Three-attempt pairing limit passed\n";
            return 0;
        }
        require(libjami::provideAccountAuthentication(destination, incorrect, "doorlight-code-v1"), "First code was not submitted");
        waitFor([&] { return !events->find(destination, false, 3, 2).empty(); }, "code retry");
        require(libjami::provideAccountAuthentication(destination, code, "doorlight-code-v1"), "Correct code was not submitted");
        Details prepared;
        waitFor([&] { prepared = events->find(destination, false, 4); return prepared["prepared"] == "true"; }, "protected import");
        require(prepared["peer_id"] == sourceDetails.at("Account.username"), "Imported account differs from source");
        require(prepared["device_id"] != sourceDevice, "Device certificate was reused");
        require(libjami::getAccountDetails(destination)["Account.enable"] == "false", "Destination enabled before preparation");
        require(libjami::getVolatileAccountDetails(destination)["Account.active"] == "false", "Destination activated before preparation");
        require(libjami::isPasswordValid(destination, destinationSecret), "Destination did not use its own protection");
        require(!libjami::isPasswordValid(destination, sourceSecret), "Source secret protects destination");
        require(!libjami::isPasswordValid(destination, code), "Pairing code protects destination");
        require(events->find(source, true, 5).empty(), "Source claimed success before destination preparation");
        auto preparedPolicy = libjami::getAccountDetails(destination);
        preparedPolicy["Account.enable"] = "false";
        preparedPolicy["Account.peerDiscovery"] = "false";
        preparedPolicy["DHT.PublicInCalls"] = "false";
        libjami::setAccountDetails(destination, preparedPolicy);
        // This fixture has no UI/privacy preferences to transfer. Its explicit
        // disabled loopback policy is the policy prepared for these test accounts.
        require(libjami::completeDeviceLinkPreparation(destination, destinationOperation), "Prepared destination refused");
        Details sourceDone, destinationDone;
        waitFor([&] { sourceDone = events->find(source, true, 5); return sourceDone.count("error"); }, "source acknowledgement");
        waitFor([&] { destinationDone = events->find(destination, false, 5); return destinationDone.count("error"); }, "destination acknowledgement");
        require(sourceDone.at("error").empty() && destinationDone.at("error").empty(), "Pairing ended unsuccessfully");
        require(libjami::getAccountDetails(destination)["Account.enable"] == "false", "Native completion bypassed host activation gate");
        require(!libjami::cancelAddDevice(source, operation), "Completed operation remained live");
        libjami::unregisterSignalHandlers();
        libjami::fini();
        std::cout << "Live pairing: separate archive secrets, retry, account/certificate binding and terminal acknowledgements passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        {
            std::lock_guard lock(events->mutex);
            for (const auto& [id, history] : events->source)
                for (const auto& event : history) std::cerr << "source state=" << event.state << '\n';
            for (const auto& [id, history] : events->destination)
                for (const auto& event : history) std::cerr << "destination state=" << event.state << '\n';
        }
        if (initialized) { libjami::unregisterSignalHandlers(); libjami::fini(); }
        return 1;
    }
}
