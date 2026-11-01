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

#include <condition_variable>
#include <set>
#include <string>
#include <fstream>
#include <streambuf>
#include <git2.h>
#include <filesystem>
#include <msgpack.hpp>

#include "manager.h"
#include "jamidht/conversation.h"
#include "jamidht/conversationrepository.h"
#include "jamidht/jamiaccount.h"
#include "jamidht/contact_list.h"
#include "../../test_runner.h"
#include "jami.h"
#include "base64.h"
#include "fileutils.h"
#include "account_const.h"
#include "common.h"

using namespace std::string_literals;
using namespace std::literals::chrono_literals;
using namespace libjami::Account;

namespace jami {
namespace test {

struct UserData
{
    std::string conversationId;
    bool removed {false};
    bool requestReceived {false};
    std::set<std::string> requestIds;
    bool requestRemoved {false};
    bool registered {false};
    bool stopped {false};
    bool deviceAnnounced {false};
    bool contactAdded {false};
    bool contactRemoved {false};
    std::string profilePath;
    std::string payloadTrustRequest;
    std::string requestMode;
    std::vector<libjami::SwarmMessage> messages;
    std::vector<libjami::SwarmMessage> messagesUpdated;
};

class ConversationRequestTest : public CppUnit::TestFixture
{
public:
    ~ConversationRequestTest() { libjami::fini(); }
    static std::string name() { return "ConversationRequest"; }
    void setUp();
    void tearDown();

    void testAcceptTrustRemoveConvReq();
    void acceptConvReqAlsoAddContact();
    void testGetRequests();
    void testDeclineRequest();
    void testTrustedGroupReinviteAfterDecline();
    void testAddContact();
    void testDeclineConversationRequestRemoveTrustRequest();
    void testMalformedTrustRequest();
    void testLateDeclinedTrustRequestKeepsNewerRequest();
    void testAddContactDeleteAndReAdd();
    void testRemoveContact();
    void testRemoveContactMultiDevice();
    void testRemoveSelfDoesntRemoveConversation();
    void testRemoveConversationUpdateContactDetails();
    void testBanContact();
    void testBanContactRestartAccount();
    void testBanContactRemoveTrustRequest();
    void testAddOfflineContactThenConnect();
    void testDeclineTrustRequestDoNotGenerateAnother();
    void testRemoveContactRemoveSyncing();
    void testRemoveConversationRemoveSyncing();
    void testCacheRequestFromClient();
    void testNeedsSyncingWithForCloning();
    void testRemoveContactRemoveTrustRequest();
    void testAddConversationNoPresenceThenConnects();
    void testRequestBigPayload();
    void testBothRemoveReadd();
    void doNotLooseMetadata();
    std::string aliceId;
    UserData aliceData;
    std::string bobId;
    UserData bobData;
    std::string bob2Id;
    UserData bob2Data;
    std::string carlaId;
    UserData carlaData;

    std::mutex mtx;
    std::condition_variable cv;

    void connectSignals();

private:
    CPPUNIT_TEST_SUITE(ConversationRequestTest);
    CPPUNIT_TEST(testAcceptTrustRemoveConvReq);
    CPPUNIT_TEST(acceptConvReqAlsoAddContact);
    CPPUNIT_TEST(testGetRequests);
    CPPUNIT_TEST(testDeclineRequest);
    CPPUNIT_TEST(testTrustedGroupReinviteAfterDecline);
    CPPUNIT_TEST(testAddContact);
    CPPUNIT_TEST(testDeclineConversationRequestRemoveTrustRequest);
    CPPUNIT_TEST(testMalformedTrustRequest);
    CPPUNIT_TEST(testLateDeclinedTrustRequestKeepsNewerRequest);
    CPPUNIT_TEST(testAddContactDeleteAndReAdd);
    CPPUNIT_TEST(testRemoveContact);
    CPPUNIT_TEST(testRemoveContactMultiDevice);
    CPPUNIT_TEST(testRemoveSelfDoesntRemoveConversation);
    CPPUNIT_TEST(testRemoveConversationUpdateContactDetails);
    CPPUNIT_TEST(testBanContact);
    CPPUNIT_TEST(testBanContactRestartAccount);
    CPPUNIT_TEST(testBanContactRemoveTrustRequest);
    CPPUNIT_TEST(testAddOfflineContactThenConnect);
    CPPUNIT_TEST(testDeclineTrustRequestDoNotGenerateAnother);
    CPPUNIT_TEST(testRemoveContactRemoveSyncing);
    CPPUNIT_TEST(testRemoveConversationRemoveSyncing);
    CPPUNIT_TEST(testCacheRequestFromClient);
    CPPUNIT_TEST(testNeedsSyncingWithForCloning);
    CPPUNIT_TEST(testRemoveContactRemoveTrustRequest);
    CPPUNIT_TEST(testAddConversationNoPresenceThenConnects);
    CPPUNIT_TEST(testRequestBigPayload);
    CPPUNIT_TEST(testBothRemoveReadd);
    CPPUNIT_TEST(doNotLooseMetadata);
    CPPUNIT_TEST_SUITE_END();
};

CPPUNIT_TEST_SUITE_NAMED_REGISTRATION(ConversationRequestTest, ConversationRequestTest::name());

void
ConversationRequestTest::setUp()
{
    // Init daemon
    libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_DEBUG | libjami::LIBJAMI_FLAG_CONSOLE_LOG));
    if (not Manager::instance().initialized)
        CPPUNIT_ASSERT(libjami::start("jami-sample.yml"));

    auto actors = load_actors("actors/alice-bob-carla.yml");
    aliceId = actors["alice"];
    bobId = actors["bob"];
    carlaId = actors["carla"];
    aliceData = {};
    bobData = {};
    bob2Data = {};
    carlaData = {};

    Manager::instance().sendRegister(carlaId, false);
    wait_for_announcement_of({aliceId, bobId});
}
void
ConversationRequestTest::connectSignals()
{
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
        [&](const std::string& accountId, const std::map<std::string, std::string>&) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId) {
                auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
                auto details = aliceAccount->getVolatileAccountDetails();
                auto daemonStatus = details[libjami::Account::ConfProperties::Registration::STATUS];
                if (daemonStatus == "REGISTERED") {
                    aliceData.registered = true;
                } else if (daemonStatus == "UNREGISTERED") {
                    aliceData.stopped = true;
                }
                auto deviceAnnounced = details[libjami::Account::VolatileProperties::DEVICE_ANNOUNCED];
                aliceData.deviceAnnounced = deviceAnnounced == "true";
            } else if (accountId == bobId) {
                auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
                auto details = bobAccount->getVolatileAccountDetails();
                auto daemonStatus = details[libjami::Account::ConfProperties::Registration::STATUS];
                if (daemonStatus == "REGISTERED") {
                    bobData.registered = true;
                } else if (daemonStatus == "UNREGISTERED") {
                    bobData.stopped = true;
                }
                auto deviceAnnounced = details[libjami::Account::VolatileProperties::DEVICE_ANNOUNCED];
                bobData.deviceAnnounced = deviceAnnounced == "true";
            } else if (accountId == bob2Id) {
                auto bob2Account = Manager::instance().getAccount<JamiAccount>(bob2Id);
                auto details = bob2Account->getVolatileAccountDetails();
                auto daemonStatus = details[libjami::Account::ConfProperties::Registration::STATUS];
                if (daemonStatus == "REGISTERED") {
                    bob2Data.registered = true;
                } else if (daemonStatus == "UNREGISTERED") {
                    bob2Data.stopped = true;
                }
                auto deviceAnnounced = details[libjami::Account::VolatileProperties::DEVICE_ANNOUNCED];
                bob2Data.deviceAnnounced = deviceAnnounced == "true";
            } else if (accountId == carlaId) {
                auto carlaAccount = Manager::instance().getAccount<JamiAccount>(carlaId);
                auto details = carlaAccount->getVolatileAccountDetails();
                auto daemonStatus = details[libjami::Account::ConfProperties::Registration::STATUS];
                if (daemonStatus == "REGISTERED") {
                    carlaData.registered = true;
                } else if (daemonStatus == "UNREGISTERED") {
                    carlaData.stopped = true;
                }
                auto deviceAnnounced = details[libjami::Account::VolatileProperties::DEVICE_ANNOUNCED];
                carlaData.deviceAnnounced = deviceAnnounced == "true";
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationReady>(
        [&](const std::string& accountId, const std::string& conversationId) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId) {
                aliceData.conversationId = conversationId;
            } else if (accountId == bobId) {
                bobData.conversationId = conversationId;
            } else if (accountId == bob2Id) {
                bob2Data.conversationId = conversationId;
            } else if (accountId == carlaId) {
                carlaData.conversationId = conversationId;
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::IncomingTrustRequest>(
        [&](const std::string& account_id,
            const std::string& /*from*/,
            const std::string& /*conversationId*/,
            const std::vector<uint8_t>& payload,
            time_t /*received*/) {
            std::lock_guard lk {mtx};
            auto payloadStr = std::string(payload.data(), payload.data() + payload.size());
            if (account_id == aliceId)
                aliceData.payloadTrustRequest = payloadStr;
            else if (account_id == bobId)
                bobData.payloadTrustRequest = payloadStr;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationRequestReceived>(
        [&](const std::string& accountId,
            const std::string& conversationId,
            std::map<std::string, std::string> metadatas) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId) {
                aliceData.requestReceived = true;
                aliceData.requestIds.insert(conversationId);
            } else if (accountId == bobId) {
                bobData.requestReceived = true;
                bobData.requestIds.insert(conversationId);
                const auto mode = metadatas.find("mode");
                bobData.requestMode = mode == metadatas.end() ? "" : mode->second;
            } else if (accountId == bob2Id) {
                bob2Data.requestReceived = true;
                bob2Data.requestIds.insert(conversationId);
            } else if (accountId == carlaId) {
                carlaData.requestReceived = true;
                carlaData.requestIds.insert(conversationId);
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationRequestDeclined>(
        [&](const std::string& accountId, const std::string&) {
            std::lock_guard lk {mtx};
            if (accountId == bobId) {
                bobData.requestRemoved = true;
            } else if (accountId == bob2Id) {
                bob2Data.requestRemoved = true;
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
        [&](const std::string& accountId, const std::string& /* conversationId */, libjami::SwarmMessage message) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId) {
                aliceData.messages.emplace_back(message);
            } else if (accountId == bobId) {
                bobData.messages.emplace_back(message);
            } else if (accountId == carlaId) {
                carlaData.messages.emplace_back(message);
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageUpdated>(
        [&](const std::string& accountId, const std::string& /* conversationId */, libjami::SwarmMessage message) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId) {
                aliceData.messagesUpdated.emplace_back(message);
            } else if (accountId == bobId) {
                bobData.messagesUpdated.emplace_back(message);
            } else if (accountId == carlaId) {
                carlaData.messagesUpdated.emplace_back(message);
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationRemoved>(
        [&](const std::string& accountId, const std::string&) {
            std::lock_guard lk {mtx};
            if (accountId == aliceId)
                aliceData.removed = true;
            else if (accountId == bobId)
                bobData.removed = true;
            else if (accountId == bob2Id)
                bob2Data.removed = true;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::ContactAdded>(
        [&](const std::string& accountId, const std::string&, bool) {
            std::lock_guard lk {mtx};
            if (accountId == bobId) {
                bobData.contactAdded = true;
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::ContactRemoved>(
        [&](const std::string& accountId, const std::string&, bool) {
            std::lock_guard lk {mtx};
            if (accountId == bobId) {
                bobData.contactRemoved = true;
            } else if (accountId == bob2Id) {
                bob2Data.contactRemoved = true;
            }
            cv.notify_one();
        }));

    libjami::registerSignalHandlers(confHandlers);
}

void
ConversationRequestTest::tearDown()
{
    auto bobArchive = std::filesystem::current_path() / "bob.gz";
    std::filesystem::remove(bobArchive);

    if (bob2Id.empty()) {
        wait_for_removal_of({aliceId, bobId, carlaId});
    } else {
        wait_for_removal_of({aliceId, bobId, carlaId, bob2Id});
    }
}

void
ConversationRequestTest::testAcceptTrustRemoveConvReq()
{
    connectSignals();
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    CPPUNIT_ASSERT_EQUAL(std::string("0"), bobData.requestMode);
    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 1);
    libjami::acceptConversationRequest(bobId, aliceData.conversationId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.conversationId.empty(); }));
    }
    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 0);
}

void
ConversationRequestTest::acceptConvReqAlsoAddContact()
{
    connectSignals();
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
        bobData.requestReceived = false;
    }

    auto convId2 = libjami::startConversation(aliceId);
    libjami::addConversationMember(aliceId, convId2, bobUri);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    libjami::acceptConversationRequest(bobId, convId2);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.conversationId.empty(); }));
    }
    std::this_thread::sleep_for(5s);
    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 0);
}

void
ConversationRequestTest::testGetRequests()
{
    connectSignals();

    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 1);
    CPPUNIT_ASSERT(requests.front()["id"] == convId);
}

void
ConversationRequestTest::testDeclineRequest()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    libjami::declineConversationRequest(bobId, convId);
    // Decline request
    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 0);
}

void
ConversationRequestTest::testTrustedGroupReinviteAfterDecline()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto aliceUri = aliceAccount->getUsername();
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    std::string directConversation;
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.requestIds.empty(); }));
        CPPUNIT_ASSERT(bobData.requestIds.size() == 1);
        directConversation = *bobData.requestIds.begin();
    }
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
            return bobData.conversationId == directConversation;
        }));
    }

    auto convId = libjami::startConversation(aliceId);
    libjami::addConversationMember(aliceId, convId, bobUri);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestIds.count(convId) == 1; }));
    }
    libjami::declineConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(libjami::getConversationRequests(bobId).empty());

    {
        std::lock_guard lk {mtx};
        bobData.requestIds.erase(convId);
    }
    Json::Value reinvite;
    reinvite[ConversationMapKeys::CONVERSATIONID] = convId;
    reinvite[ConversationMapKeys::METADATAS]["mode"] = "1";
    bobAccount->convModule()->onConversationRequest(aliceUri, reinvite);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 5s, [&]() { return bobData.requestIds.count(convId) == 1; }));
    }
    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 1);
    CPPUNIT_ASSERT(requests.front()["id"] == convId);
}

void
ConversationRequestTest::testAddContact()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 5s, [&]() { return !aliceData.conversationId.empty(); }));
    }
    ConversationRepository repo(aliceAccount, aliceData.conversationId);
    // Mode must be one to one
    CPPUNIT_ASSERT(repo.mode() == ConversationMode::ONE_TO_ONE);
    // Assert that repository exists
    auto repoPath = fileutils::get_data_dir() / aliceId / "conversations" / aliceData.conversationId;
    CPPUNIT_ASSERT(std::filesystem::is_directory(repoPath));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
            return !bobData.conversationId.empty() && aliceMsgSize + 1 == aliceData.messages.size();
        }));
    }
    auto clonedPath = fileutils::get_data_dir() / bobId / "conversations" / aliceData.conversationId;
    CPPUNIT_ASSERT(std::filesystem::is_directory(clonedPath));
    auto bobMember = clonedPath / "members" / (bobUri + ".crt");
    CPPUNIT_ASSERT(std::filesystem::is_regular_file(bobMember));
}

void
ConversationRequestTest::testDeclineConversationRequestRemoveTrustRequest()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    // Decline request
    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 1);
    auto trustRequests = libjami::getTrustRequests(bobId);
    CPPUNIT_ASSERT(trustRequests.size() == 1);
    libjami::declineConversationRequest(bobId, aliceData.conversationId);
    requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 0);
    trustRequests = libjami::getTrustRequests(bobId);
    CPPUNIT_ASSERT(trustRequests.size() == 0);
}

void
ConversationRequestTest::testLateDeclinedTrustRequestKeepsNewerRequest()
{
    const auto alice = Manager::instance().getAccount<JamiAccount>(aliceId);
    const auto bob = Manager::instance().getAccount<JamiAccount>(bobId);
    const auto uri = alice->getUsername();
    const dht::InfoHash peer(uri);
    const auto device = alice->identity().second->getSharedPublicKey();
    const auto manager = bob->accountManager();
    const auto* info = manager->getInfo();
    CPPUNIT_ASSERT(info && info->contacts);
    const auto& contacts = info->contacts;
    auto* conversations = bob->convModule();
    const std::string declined(40, '1');
    const std::string replacement(40, '2');
    // Inject the already-authenticated contact-list/callback boundary in an
    // explicit order. confirm=true suppresses its asynchronous callback while
    // the peer is not a contact, allowing exact late-callback interleavings.
    const auto insert = [&](const std::string& id) {
        contacts->onTrustRequest(peer, device, nowMs(), true, id, {});
    };
    insert(declined);
    conversations->onTrustRequest(uri, declined, {}, nowMs());
    CPPUNIT_ASSERT_EQUAL(size_t(1), bob->getTrustRequests().size());
    conversations->declineConversationRequest(declined);
    CPPUNIT_ASSERT(contacts->discardTrustRequest(peer));
    insert(declined);
    conversations->onTrustRequest(uri, declined, {}, nowMs());
    CPPUNIT_ASSERT_MESSAGE("A late duplicate must not resurrect a declined trust request",
                           bob->getTrustRequests().empty());
    CPPUNIT_ASSERT(conversations->getConversationRequests().empty());

    insert(replacement);
    conversations->onTrustRequest(uri, replacement, {}, nowMs());
    // The older callback is delayed until a different request from the same
    // authenticated peer has already replaced the contact-list entry.
    conversations->onTrustRequest(uri, declined, {}, nowMs());
    const auto current = bob->getTrustRequests();
    CPPUNIT_ASSERT_EQUAL(size_t(1), current.size());
    CPPUNIT_ASSERT_EQUAL(replacement, current.front().at(libjami::Account::TrustRequest::CONVERSATIONID));
    const auto requests = conversations->getConversationRequests();
    CPPUNIT_ASSERT_EQUAL(size_t(1), requests.size());
    CPPUNIT_ASSERT_EQUAL(replacement, requests.front().at("id"));
}

void
ConversationRequestTest::testMalformedTrustRequest()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    // Decline request
    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 1);
    auto trustRequests = libjami::getTrustRequests(bobId);
    CPPUNIT_ASSERT(trustRequests.size() == 1);
    // This will let the trust request (not libjami::declineConversationRequest)
    bobAccount->convModule()->declineConversationRequest(aliceData.conversationId);
    requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 0);
    trustRequests = libjami::getTrustRequests(bobId);
    CPPUNIT_ASSERT(trustRequests.size() == 1);
    // Reload conversation will fix the state (the trustRequest is removed in another thread)
    bobAccount->convModule()->loadConversations();
    requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 0);

    auto start = std::chrono::steady_clock::now();

    auto requestDeclined = false;
    do {
        trustRequests = libjami::getTrustRequests(bobId);
        requestDeclined = trustRequests.size() == 0;
        if (!requestDeclined)
            std::this_thread::sleep_for(1s);
    } while (not requestDeclined and std::chrono::steady_clock::now() - start < 2s);

    CPPUNIT_ASSERT(requestDeclined);
}

void
ConversationRequestTest::testAddContactDeleteAndReAdd()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
            return !bobData.conversationId.empty() && aliceMsgSize + 1 == aliceData.messages.size();
        }));
    }

    // removeContact
    aliceAccount->removeContact(bobUri, false);
    std::this_thread::sleep_for(5s); // wait a bit that connections are closed

    // re-add
    CPPUNIT_ASSERT(aliceData.conversationId != "");
    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Should retrieve previous conversation
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceData.conversationId == bobData.conversationId; }));
    }
}

void
ConversationRequestTest::testRemoveContact()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Check created files
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    }

    bobAccount->removeContact(aliceUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.removed; }));
    }
    auto details = bobAccount->getContactDetails(aliceUri);
    CPPUNIT_ASSERT(details.find("removed") != details.end() && details["removed"] != "0");

    aliceAccount->removeContact(bobUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 20s, [&]() { return aliceData.removed; }));
    }

    std::this_thread::sleep_for(5s); // There is no signal, but daemon should then erase the repository

    auto repoPath = fileutils::get_data_dir() / aliceId / "conversations" / aliceData.conversationId;
    CPPUNIT_ASSERT(!std::filesystem::is_directory(repoPath));

    repoPath = fileutils::get_data_dir() / bobId / "conversations" / bobData.conversationId;
    CPPUNIT_ASSERT(!std::filesystem::is_directory(repoPath));
}

void
ConversationRequestTest::testRemoveContactMultiDevice()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    // Add second device for Bob
    auto bobArchive = std::filesystem::current_path() / "bob.gz";
    std::filesystem::remove(bobArchive);
    bobAccount->exportArchive(bobArchive);

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::TYPE] = "RING";
    details[ConfProperties::DISPLAYNAME] = "BOB2";
    details[ConfProperties::ALIAS] = "BOB2";
    details[ConfProperties::UPNP_ENABLED] = "true";
    details[ConfProperties::ARCHIVE_PASSWORD] = "";
    details[ConfProperties::ARCHIVE_PATH] = bobArchive;

    bob2Id = Manager::instance().addAccount(details);

    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bob2Data.deviceAnnounced; }));
    }
    // First, Alice adds Bob
    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived && bob2Data.requestReceived; }));
    }

    // Bob1 decline via removeContact, both device should remove the request
    bobAccount->removeContact(aliceUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestRemoved && bob2Data.requestRemoved; }));
    }
}

void
ConversationRequestTest::testRemoveSelfDoesntRemoveConversation()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Check created files
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    }
    aliceAccount->removeContact(aliceUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(!cv.wait_for(lk, 10s, [&]() { return aliceData.removed; }));
    }
    auto repoPath = fileutils::get_data_dir() / aliceId / "conversations" / aliceData.conversationId;
    CPPUNIT_ASSERT(std::filesystem::is_directory(repoPath));
}

void
ConversationRequestTest::testRemoveConversationUpdateContactDetails()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Check created files
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    }
    auto oldConvId = bobData.conversationId;
    libjami::removeConversation(bobId, bobData.conversationId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.removed; }));
    }

    auto details = bobAccount->getContactDetails(aliceUri);
    CPPUNIT_ASSERT(details[libjami::Account::TrustRequest::CONVERSATIONID] != oldConvId);
}

void
ConversationRequestTest::testBanContact()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Check created files
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    }
    bobAccount->removeContact(aliceUri, true);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(!cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 2 == aliceData.messages.size(); }));
    }
    auto repoPath = fileutils::get_data_dir() / bobId / "conversations" / bobData.conversationId;
    CPPUNIT_ASSERT(std::filesystem::is_directory(repoPath));
}

void
ConversationRequestTest::testBanContactRestartAccount()
{
    const auto alice = Manager::instance().getAccount<JamiAccount>(aliceId);
    const auto bob = Manager::instance().getAccount<JamiAccount>(bobId);
    const auto aliceUri = alice->getUsername();
    const auto bobUri = bob->getUsername();
    struct State {
        std::mutex mutex;
        std::condition_variable changed;
        std::string conversation;
        bool request = false, joined = false, removed = false;
        bool registered = false, announced = false, restarting = false;
        bool failed = false, revived = false, receivedProbe = false;
    };
    const auto state = std::make_shared<State>();
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> handlers;
    handlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::IncomingTrustRequest>(
        [state, account = bobId, aliceUri](const std::string& id, const std::string& conversation,
            const std::string& from, const std::vector<uint8_t>&, time_t) {
            if (id != account || from != aliceUri) return;
            std::lock_guard guard(state->mutex);
            state->conversation = conversation;
            state->request = true;
            state->changed.notify_all();
        }));
    handlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
        [state, source = aliceId, destination = bobId](const std::string& id, const std::string& conversation,
            const libjami::SwarmMessage& message) {
            std::lock_guard guard(state->mutex);
            if (conversation != state->conversation) return;
            if (id == source && message.type == CommitType::MEMBER) state->joined = true;
            const auto body = message.body.find(CommitKey::BODY);
            if (id == destination && body != message.body.end()
                && body->second == "blocked-after-restart-probe") state->receivedProbe = true;
            state->changed.notify_all();
        }));
    handlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::ContactRemoved>(
        [state, account = bobId, aliceUri](const std::string& id, const std::string& uri, bool banned) {
            if (id != account || uri != aliceUri || !banned) return;
            std::lock_guard guard(state->mutex);
            state->removed = true;
            state->changed.notify_all();
        }));
    handlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
        [state, account = bobId](const std::string& id, const std::map<std::string, std::string>& details) {
            if (id != account) return;
            std::lock_guard guard(state->mutex);
            const auto registration = details.find(libjami::Account::ConfProperties::Registration::STATUS);
            const auto announcement = details.find(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED);
            // VolatileDetailsChanged may contain only the changed fields.
            if (registration != details.end()) state->registered = registration->second == "REGISTERED";
            if (announcement != details.end()) state->announced = announcement->second == "true";
            state->changed.notify_all();
        }));
    libjami::registerSignalHandlers(handlers);
    // Ban disconnects an already-connected swarm immediately. Install this
    // exact-conversation observer before that edge, not after unregistering.
    bob->convModule()->onBootstrapStatus([state](std::string conversation, Conversation::BootstrapStatus status) {
        std::lock_guard guard(state->mutex);
        if (conversation != state->conversation) return;
        if (status == Conversation::BootstrapStatus::FAILED) state->failed = true;
        if (state->restarting && status == Conversation::BootstrapStatus::SUCCESS) state->revived = true;
        state->changed.notify_all();
    });
    auto wait = [&](auto predicate, auto duration) {
        std::unique_lock guard(state->mutex);
        return state->changed.wait_for(guard, duration, predicate);
    };
    alice->addContact(bobUri);
    alice->sendTrustRequest(bobUri, {});
    CPPUNIT_ASSERT(wait([&] { return state->request && !state->conversation.empty(); }, 30s));
    const auto conversationId = state->conversation;
    CPPUNIT_ASSERT(bob->acceptTrustRequest(aliceUri));
    CPPUNIT_ASSERT(wait([&] { return state->joined; }, 30s));
    const auto conversation = bob->convModule()->getConversation(conversationId);
    CPPUNIT_ASSERT(conversation);
    CPPUNIT_ASSERT(conversation->isBootstrapped());
    bob->removeContact(aliceUri, true);
    CPPUNIT_ASSERT(wait([&] { return state->removed; }, 30s));
    CPPUNIT_ASSERT(wait([&] { return state->failed; }, 60s));
    CPPUNIT_ASSERT(!conversation->isBootstrapped());
    Manager::instance().sendRegister(bobId, false);
    CPPUNIT_ASSERT(wait([&] { return !state->registered; }, 30s));
    {
        std::lock_guard guard(state->mutex);
        state->restarting = true;
        state->registered = state->announced = false;
    }
    Manager::instance().sendRegister(bobId, true);
    CPPUNIT_ASSERT(wait([&] { return state->registered && state->announced; }, 30s));
    // A disconnected swarm need not emit a duplicate FAILED edge. Check the
    // actual post-restart boundary: ban persists, no connection can revive,
    // and a newly published authenticated peer message cannot be delivered.
    CPPUNIT_ASSERT_EQUAL("true"s, bob->getContactDetails(aliceUri).at("banned"));
    CPPUNIT_ASSERT(!conversation->isBootstrapped());
    auto published = std::make_shared<std::promise<std::pair<bool, std::string>>>();
    auto result = published->get_future();
    alice->convModule()->createCommit(conversationId,
        CommitMessage::text("blocked-after-restart-probe"), true, {},
        [published](bool ok, const std::string& id) { published->set_value({ok, id}); });
    CPPUNIT_ASSERT(result.wait_for(10s) == std::future_status::ready);
    const auto publication = result.get();
    CPPUNIT_ASSERT(publication.first && !publication.second.empty());
    CPPUNIT_ASSERT(!wait([&] { return state->revived || state->receivedProbe; }, 30s));
    CPPUNIT_ASSERT(!conversation->isBootstrapped());
    auto loaded = std::make_shared<std::promise<std::vector<libjami::SwarmMessage>>>();
    auto snapshot = loaded->get_future();
    conversation->loadMessageSnapshot([loaded](auto messages) { loaded->set_value(std::move(messages)); }, publication.second);
    CPPUNIT_ASSERT(snapshot.wait_for(10s) == std::future_status::ready);
    CPPUNIT_ASSERT(snapshot.get().empty());
}

void
ConversationRequestTest::testBanContactRemoveTrustRequest()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    // Check created files
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    bobAccount->removeContact(aliceUri, true);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 5s, [&]() { return bobData.requestRemoved; }));
    }
    auto requests = libjami::getConversationRequests(bobId);
    CPPUNIT_ASSERT(requests.size() == 0);
}

void
ConversationRequestTest::testAddOfflineContactThenConnect()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto carlaAccount = Manager::instance().getAccount<JamiAccount>(carlaId);
    auto carlaUri = carlaAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    aliceAccount->trackBuddyPresence(carlaUri, true);

    aliceAccount->addContact(carlaUri);
    aliceAccount->sendTrustRequest(carlaUri, {});
    std::this_thread::sleep_for(5s); // Wait 5 secs for the put to happen
    Manager::instance().sendRegister(carlaId, true);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(60), [&]() { return carlaData.requestReceived; }));
    }
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(carlaAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceData.messages.size() == aliceMsgSize + 1; }));
    }
}

void
ConversationRequestTest::testDeclineTrustRequestDoNotGenerateAnother()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    aliceAccount->trackBuddyPresence(bobUri, true);

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    CPPUNIT_ASSERT(bobAccount->discardTrustRequest(aliceUri));
    std::this_thread::sleep_for(10s); // Wait a bit
    Manager::instance().sendRegister(bobId, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.stopped; }));
    }
    // Trigger on peer online
    bobData.deviceAnnounced = false;
    bobData.requestReceived = false;
    Manager::instance().sendRegister(bobId, true);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.deviceAnnounced; }));
        CPPUNIT_ASSERT(!cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
}

void
ConversationRequestTest::testRemoveContactRemoveSyncing()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    Manager::instance().sendRegister(aliceId, false); // This avoid to sync immediately
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.contactAdded; }));
    }

    CPPUNIT_ASSERT(libjami::getConversations(bobId).size() == 1);
    bobAccount->removeContact(aliceUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.contactRemoved; }));
    }

    CPPUNIT_ASSERT(libjami::getConversations(bobId).size() == 0);
}

void
ConversationRequestTest::testRemoveConversationRemoveSyncing()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    Manager::instance().sendRegister(aliceId, false); // This avoid to sync immediately
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.contactAdded; }));
    }
    // At this point the conversation should be there and syncing.

    CPPUNIT_ASSERT(libjami::getConversations(bobId).size() == 1);
    auto oldConvId = aliceData.conversationId;
    CPPUNIT_ASSERT(libjami::removeConversation(bobId, aliceData.conversationId));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.conversationId != oldConvId; }));
    }
}

void
ConversationRequestTest::testCacheRequestFromClient()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);
    std::vector<uint8_t> payload = {0x64, 0x64, 0x64};
    aliceAccount->sendTrustRequest(bobUri,
                                   payload); // Random payload, just care with the file
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    auto cachedPath = fileutils::get_cache_dir() / aliceId / "requests" / bobUri;
    CPPUNIT_ASSERT(std::filesystem::is_regular_file(cachedPath));
    CPPUNIT_ASSERT(fileutils::loadFile(cachedPath) == payload);

    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 1);
    libjami::acceptConversationRequest(bobId, aliceData.conversationId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.conversationId.empty(); }));
    }
    // cachedPath is removed on confirmation (from the DHT), so this can take a few secs to come
    auto removed = false;
    for (int i = 0; i <= 10; ++i) {
        if (!std::filesystem::is_regular_file(cachedPath)) {
            removed = true;
            break;
        }
        std::this_thread::sleep_for(1s);
    }
    CPPUNIT_ASSERT(removed);
}

void
ConversationRequestTest::testNeedsSyncingWithForCloning()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    auto aliceDevice = std::string(aliceAccount->currentDeviceId());

    CPPUNIT_ASSERT(!bobAccount->convModule()->needsSyncingWith(aliceUri));
    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    Manager::instance().sendRegister(aliceId, false); // This avoid to sync immediately
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.contactAdded; }));
    }
    // At this point the conversation should be there and syncing.

    CPPUNIT_ASSERT(libjami::getConversations(bobId).size() == 1);
    CPPUNIT_ASSERT(bobAccount->convModule()->needsSyncingWith(aliceUri));
}

void
ConversationRequestTest::testRemoveContactRemoveTrustRequest()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    // Add second device for Bob
    auto bobArchive = std::filesystem::current_path().string() + "/bob.gz";
    std::remove(bobArchive.c_str());
    bobAccount->exportArchive(bobArchive);

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::TYPE] = "RING";
    details[ConfProperties::DISPLAYNAME] = "BOB2";
    details[ConfProperties::ALIAS] = "BOB2";
    details[ConfProperties::UPNP_ENABLED] = "true";
    details[ConfProperties::ARCHIVE_PASSWORD] = "";
    details[ConfProperties::ARCHIVE_PATH] = bobArchive;

    bob2Id = Manager::instance().addAccount(details);

    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bob2Data.deviceAnnounced; }));
    }
    auto bob2Account = Manager::instance().getAccount<JamiAccount>(bob2Id);

    // First, Alice adds Bob
    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived && bob2Data.requestReceived; }));
    }

    // Bob1 accepts, both device should get it
    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
            return !bobData.conversationId.empty() && !bob2Data.conversationId.empty()
                   && aliceMsgSize + 1 == aliceData.messages.size();
        }));
    };

    // Bob2 remove Alice ; Bob1 should not have any trust requests
    bob2Account->removeContact(aliceUri, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.contactRemoved && bob2Data.contactRemoved; }));
    }
    std::this_thread::sleep_for(10s); // Wait a bit to ensure that everything is update (via synced)
    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 0);
    CPPUNIT_ASSERT(bob2Account->getTrustRequests().size() == 0);
}

void
ConversationRequestTest::testAddConversationNoPresenceThenConnects()
{
    const auto alice = Manager::instance().getAccount<JamiAccount>(aliceId);
    const auto carla = Manager::instance().getAccount<JamiAccount>(carlaId);
    const auto aliceUri = alice->getUsername();
    const auto carlaUri = carla->getUsername();
    struct State {
        std::mutex mutex;
        std::condition_variable changed;
        std::string aliceConversation, carlaConversation;
        bool registered = false, announced = false;
        std::set<std::string> received;
    };
    const auto state = std::make_shared<State>();
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> handlers;
    handlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationReady>(
        [state, aliceAccount = aliceId, carlaAccount = carlaId](const std::string& account, const std::string& conversation) {
            std::lock_guard guard(state->mutex);
            if (account == aliceAccount) state->aliceConversation = conversation;
            if (account == carlaAccount) state->carlaConversation = conversation;
            state->changed.notify_all();
        }));
    handlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
        [state, account = carlaId](const std::string& id, const std::map<std::string, std::string>& details) {
            if (id != account) return;
            std::lock_guard guard(state->mutex);
            const auto registration = details.find(libjami::Account::ConfProperties::Registration::STATUS);
            const auto announcement = details.find(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED);
            // VolatileDetailsChanged may contain only the changed fields.
            if (registration != details.end()) state->registered = registration->second == "REGISTERED";
            if (announcement != details.end()) state->announced = announcement->second == "true";
            state->changed.notify_all();
        }));
    handlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
        [state, account = aliceId](const std::string& id, const std::string& conversation, const libjami::SwarmMessage& message) {
            std::lock_guard guard(state->mutex);
            if (id != account || conversation != state->carlaConversation) return;
            state->received.insert(message.id);
            state->changed.notify_all();
        }));
    libjami::registerSignalHandlers(handlers);
    auto wait = [&](auto predicate, auto duration) {
        std::unique_lock guard(state->mutex);
        return state->changed.wait_for(guard, duration, predicate);
    };
    alice->trackBuddyPresence(carlaUri, true);
    carla->publishPresence(false);
    alice->addContact(carlaUri);
    std::this_thread::sleep_for(5s);
    Manager::instance().sendRegister(carlaId, true);
    // Presence is intentionally unpublished until the later transition.
    CPPUNIT_ASSERT(wait([&] { return state->registered; }, 30s));
    carla->addContact(aliceUri);
    CPPUNIT_ASSERT(wait([&] { return !state->carlaConversation.empty(); }, 30s));
    std::string conversationId;
    {
        std::lock_guard guard(state->mutex);
        conversationId = state->carlaConversation;
    }
    std::this_thread::sleep_for(5s);
    carla->publishPresence(true);
    Manager::instance().sendRegister(carlaId, false);
    CPPUNIT_ASSERT(wait([&] { return !state->registered; }, 30s));
    {
        std::lock_guard guard(state->mutex);
        state->registered = state->announced = false;
    }
    // Carla already owns this conversation. Restarting its transport does not
    // recreate it, so retain the exact observed ID instead of requiring a
    // duplicate ConversationReady notification from the creator.
    Manager::instance().sendRegister(carlaId, true);
    CPPUNIT_ASSERT(wait([&] { return state->registered && state->announced; }, 30s));
    CPPUNIT_ASSERT(wait([&] { return state->aliceConversation == conversationId
                                  && state->carlaConversation == conversationId; }, 30s));
    const auto carlaDetails = carla->getContactDetails(aliceUri);
    const auto aliceDetails = alice->getContactDetails(carlaUri);
    CPPUNIT_ASSERT(carlaDetails.at("conversationId") == aliceDetails.at("conversationId")
                   && aliceDetails.at("conversationId") == conversationId);
    const auto conversation = carla->convModule()->getConversation(conversationId);
    CPPUNIT_ASSERT(conversation && alice->convModule()->getConversation(conversationId));
    // Current state is not enough: require a real post-restart publication and
    // delivery to the peer, correlated to the returned authenticated commit.
    auto published = std::make_shared<std::promise<std::pair<bool, std::string>>>();
    auto result = published->get_future();
    carla->convModule()->createCommit(conversationId, CommitMessage::text("presence-restart-probe"), true, {},
        [published](bool ok, const std::string& id) { published->set_value({ok, id}); });
    CPPUNIT_ASSERT(result.wait_for(10s) == std::future_status::ready);
    const auto publication = result.get();
    CPPUNIT_ASSERT(publication.first && !publication.second.empty());
    CPPUNIT_ASSERT(wait([&] { return state->received.count(publication.second) != 0; }, 30s));
}

void
ConversationRequestTest::testRequestBigPayload()
{
    connectSignals();
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    aliceAccount->addContact(bobUri);

    auto data = std::string(64000, 'A');
    std::vector<uint8_t> payload(data.begin(), data.end());
    aliceAccount->sendTrustRequest(bobUri, payload);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 1);
    libjami::acceptConversationRequest(bobId, aliceData.conversationId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.conversationId.empty(); }));
    }
    CPPUNIT_ASSERT(bobAccount->getTrustRequests().size() == 0);
}

void
ConversationRequestTest::testBothRemoveReadd()
{
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();

    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !bobData.conversationId.empty(); }));
    }

    // removeContact
    aliceAccount->removeContact(bobUri, false);
    bobAccount->removeContact(aliceUri, false);
    std::this_thread::sleep_for(5s); // wait a bit that connections are closed

    // re-add
    aliceData.conversationId.clear();
    bobData.requestReceived = false;
    aliceAccount->addContact(bobUri);
    aliceAccount->sendTrustRequest(bobUri, {});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }
    CPPUNIT_ASSERT(bobAccount->acceptTrustRequest(aliceUri));
    // Should retrieve previous conversation
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
            return !aliceData.conversationId.empty() && bobData.conversationId == aliceData.conversationId;
        }));
    }
}

void
ConversationRequestTest::doNotLooseMetadata()
{
    std::cout << "\nRunning test: " << __func__ << std::endl;
    connectSignals();

    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();

    libjami::startConversation(aliceId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceData.conversationId != ""; }));
    }

    auto aliceMsgSize = aliceData.messages.size();
    aliceAccount->convModule()->updateConversationInfos(aliceData.conversationId, {{"title", "My awesome swarm"}});
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    }

    libjami::addConversationMember(aliceId, aliceData.conversationId, bobUri);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));
    }

    Manager::instance().sendRegister(aliceId, false);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceData.stopped; }));
    }

    libjami::acceptConversationRequest(bobId, aliceData.conversationId);
    {
        std::unique_lock lk {mtx};
        CPPUNIT_ASSERT(!cv.wait_for(lk, 10s, [&]() { return bobData.conversationId != ""; }));
    }

    // Force reset
    bobAccount->convModule()->loadConversations();
    auto infos = libjami::conversationInfos(bobId, aliceData.conversationId);
    CPPUNIT_ASSERT(infos["syncing"] == "true");
    CPPUNIT_ASSERT(infos["title"] == "My awesome swarm");
}

} // namespace test
} // namespace jami

CORE_TEST_RUNNER(jami::test::ConversationRequestTest::name())
