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

#include <cppunit/TestAssert.h>
#include <cppunit/TestFixture.h>
#include <cppunit/extensions/HelperMacros.h>

#include <yaml-cpp/yaml.h>

#include "common.h"

/* Jami */
#include "account_const.h"
#include "jami.h"
#include "fileutils.h"
#include "manager.h"

#include <algorithm>
#include <condition_variable>
#include <exception>
#include <memory>
#include <mutex>

/* Make GCC quiet about unused functions */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"

void
wait_for_announcement_of(const std::vector<std::string> accountIDs, std::chrono::seconds timeout)
{
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    std::mutex mtx;
    std::unique_lock lk {mtx};
    std::condition_variable cv;
    std::vector<std::atomic_bool> accountsReady(accountIDs.size());

    size_t to_be_announced = accountIDs.size();

    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
        [&, accountIDs = std::move(accountIDs)](const std::string& accountID,
                                                const std::map<std::string, std::string>& details) {
            for (size_t i = 0; i < accountIDs.size(); ++i) {
                if (accountIDs[i] != accountID) {
                    continue;
                }

                if (jami::Manager::instance().getAccount(accountID)->getAccountType() == "SIP") {
                    auto daemonStatus = details.at(libjami::Account::ConfProperties::Registration::STATUS);
                    if (daemonStatus != "REGISTERED") {
                        continue;
                    }
                } else {
                    try {
                        if ("true" != details.at(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED)) {
                            continue;
                        }
                    } catch (const std::out_of_range&) {
                        continue;
                    }
                }

                accountsReady[i] = true;
                cv.notify_one();
            }
        }));

    JAMI_LOG("Waiting for {} account to be announced...", to_be_announced);

    libjami::registerSignalHandlers(confHandlers);

    CPPUNIT_ASSERT(cv.wait_for(lk, timeout, [&] {
        for (const auto& rdy : accountsReady) {
            if (not rdy) {
                return false;
            }
        }

        return true;
    }));

    libjami::unregisterSignalHandlers();

    JAMI_LOG("{} account announced!", to_be_announced);
}

void
wait_for_announcement_of(const std::string& accountId, std::chrono::seconds timeout)
{
    wait_for_announcement_of(std::vector<std::string> {accountId}, timeout);
}

void
wait_for_removal_of(const std::vector<std::string> accounts, std::chrono::seconds timeout)
{
    // Account counts cannot prove that these actors were removed: stale or
    // duplicate ids and unrelated account changes must not satisfy the wait.
    struct State {
        std::mutex mutex;
        std::condition_variable changed;
        bool removed {false};
    };
    const auto state = std::make_shared<State>();
    const auto observe = [state, accounts] {
        const auto current = jami::Manager::instance().getAccountList();
        const bool removed = std::all_of(accounts.begin(), accounts.end(), [&](const auto& id) {
            return id.empty() || std::find(current.begin(), current.end(), id) == current.end();
        });
        std::lock_guard lock(state->mutex);
        state->removed = removed;
        state->changed.notify_all();
    };
    // A timeout must not leave callbacks referring to destroyed stack state.
    struct ReleaseHandlers {
        ~ReleaseHandlers() { libjami::unregisterSignalHandlers(); }
    } release;
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> handlers;
    handlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::AccountsChanged>(observe));
    libjami::unregisterSignalHandlers();
    libjami::registerSignalHandlers(handlers);
    for (const auto& id : accounts) {
        if (!id.empty() && jami::Manager::instance().getAccount(id))
            jami::Manager::instance().removeAccount(id, true);
    }
    // Observe after subscribing/removing, including the already-absent case.
    observe();
    std::unique_lock lock(state->mutex);
    CPPUNIT_ASSERT(state->changed.wait_for(lock, timeout, [&] { return state->removed; }));
}

void
wait_for_removal_of(const std::string& account, std::chrono::seconds timeout)
{
    wait_for_removal_of(std::vector<std::string> {account}, timeout);
}

std::map<std::string, std::string>
load_actors(const std::filesystem::path& from_yaml)
{
    std::map<std::string, std::string> actors {};

    std::ifstream file(from_yaml);

    CPPUNIT_ASSERT(file.is_open());

    YAML::Node node = YAML::Load(file);

    CPPUNIT_ASSERT(node.IsMap());

    auto default_account = node["default-account"];

    std::map<std::string, std::string> default_details = libjami::getAccountTemplate(
        default_account["type"].as<std::string>());
    if (default_account.IsMap()) {
        for (const auto& kv : default_account) {
            auto key = kv.first.as<std::string>();
            if (default_details.find(key) != default_details.end()) {
                default_details[key] = kv.second.as<std::string>();
            } else {
                default_details["Account." + key] = kv.second.as<std::string>();
            }
        }
    }

    auto accounts = node["accounts"];

    CPPUNIT_ASSERT(accounts.IsMap());

    for (const auto& kv : accounts) {
        auto account_name = kv.first.as<std::string>();
        auto account = kv.second.as<YAML::Node>();
        auto details = std::map<std::string, std::string>(default_details);

        for (const auto& detail : account) {
            auto key = detail.first.as<std::string>();
            if (details.find(key) != details.end()) {
                details[key] = detail.second.as<std::string>();
            } else {
                details["Account." + key] = detail.second.as<std::string>();
            }
        }

        actors[account_name] = jami::Manager::instance().addAccount(details);
    }

    return actors;
}

std::map<std::string, std::string>
load_actors_and_wait_for_announcement(const std::string& from_yaml)
{
    auto actors = load_actors(from_yaml);

    std::vector<std::string> wait_for;

    wait_for.reserve(actors.size());

    for (auto it = actors.cbegin(); it != actors.cend(); ++it) {
        wait_for.emplace_back(it->second);
    }

    try {
        wait_for_announcement_of(wait_for);
    } catch (...) {
        // The caller has not received these ids yet. Teardown otherwise sees
        // its previous actors and can leak this whole newly-created batch.
        const auto failure = std::current_exception();
        try {
            wait_for_removal_of(wait_for);
        } catch (...) {
            JAMI_ERROR("Failed to remove the exact actors after announcement timeout");
        }
        std::rethrow_exception(failure); // preserve the original failed assertion
    }

    return actors;
}

#pragma GCC diagnostic pop
