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

#include "fileutils.h"
#include "manager.h"

#include "jamidht/jamiaccount.h"
#include "../../test_runner.h"
#include "jami.h"
#include "data_transfer.h"
#include "jami/datatransfer_interface.h"
#include "account_const.h"
#include "common.h"

#include <dhtnet/connectionmanager.h>

#include <cppunit/TestAssert.h>
#include <cppunit/TestFixture.h>
#include <cppunit/extensions/HelperMacros.h>

#include <condition_variable>
#include <cstdlib>
#include <string>
#include <filesystem>

using namespace std::literals::chrono_literals;
using namespace libjami::Account;
using namespace std::literals::chrono_literals;

namespace jami {
namespace test {

struct UserData
{
    std::string conversationId;
    bool removed {false};
    bool requestReceived {false};
    bool registered {false};
    bool stopped {false};
    bool deviceAnnounced {false};
    std::string seededCommit;
    std::string seededFile;
    bool ownedSeedVisibleWithMessage {false};
    int code {0};
    std::vector<libjami::SwarmMessage> messages;
    std::vector<libjami::SwarmMessage> messagesUpdated;
};

class FileTransferTest : public CppUnit::TestFixture
{
public:
    FileTransferTest()
    {
        // Init daemon
        libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_DEBUG | libjami::LIBJAMI_FLAG_CONSOLE_LOG));
        if (not Manager::instance().initialized)
            CPPUNIT_ASSERT(libjami::start("jami-sample.yml"));
    }
    ~FileTransferTest() { libjami::fini(); }
    static std::string name() { return "Call"; }
    bool compare(const std::string& fileA, const std::string& fileB) const;
    void setUp();
    void tearDown();

    std::string aliceId;
    UserData aliceData;
    std::string bobId;
    UserData bobData;
    std::string carlaId;
    UserData carlaData;

    std::filesystem::path sendPath {std::filesystem::current_path() / "SEND"};
    std::filesystem::path recvPath {std::filesystem::current_path() / "RECV"};
    std::filesystem::path recv2Path {std::filesystem::current_path() / "RECV2"};

    std::mutex mtx;
    std::unique_lock<std::mutex> lk {mtx};
    std::condition_variable cv;

    void connectSignals();

private:
    void testConversationFileTransfer();
    void testFileTransferInConversation();
    void testVcfFileTransferInConversation();
    void testBadSha3sumOut();
    void testBadSha3sumIn();
    void testAskToMultipleParticipants();
    void testCancelInTransfer();
    void testResumeTransferAfterInterruption();
    void testDontDownloadExistingFile();
    void testTransferInfo();
    void testRemoveHardLink();
    void testTooLarge();
    void testDeleteFile();
    void testWaitingAttemptOwnership();
    void testRepairOwnedSeed();
    void testReceiveBelowSearchOnlyAncestor();
    void testPublicationFailurePreservesDestination();

    CPPUNIT_TEST_SUITE(FileTransferTest);
    CPPUNIT_TEST(testConversationFileTransfer);
    CPPUNIT_TEST(testFileTransferInConversation);
    CPPUNIT_TEST(testVcfFileTransferInConversation);
    CPPUNIT_TEST(testBadSha3sumOut);
    CPPUNIT_TEST(testBadSha3sumIn);
    CPPUNIT_TEST(testAskToMultipleParticipants);
    CPPUNIT_TEST(testCancelInTransfer);
    CPPUNIT_TEST(testResumeTransferAfterInterruption);
    CPPUNIT_TEST(testDontDownloadExistingFile);
    CPPUNIT_TEST(testTransferInfo);
    CPPUNIT_TEST(testRemoveHardLink);
    CPPUNIT_TEST(testTooLarge);
    CPPUNIT_TEST(testDeleteFile);
    CPPUNIT_TEST(testWaitingAttemptOwnership);
    CPPUNIT_TEST(testRepairOwnedSeed);
    CPPUNIT_TEST(testReceiveBelowSearchOnlyAncestor);
    CPPUNIT_TEST(testPublicationFailurePreservesDestination);
    CPPUNIT_TEST_SUITE_END();
};

CPPUNIT_TEST_SUITE_NAMED_REGISTRATION(FileTransferTest, FileTransferTest::name());

void FileTransferTest::testWaitingAttemptOwnership()
{
    const std::string conversation(40, 'a');
    const std::string commit(40, 'b');
    const std::string file = commit + "_1";
    const std::string hash(128, 'c');
    std::mt19937_64 random(123);
    auto manager = std::make_shared<TransferManager>(aliceId, "", conversation, random);
    manager->waitForTransfer(file, commit, hash, recvPath.string(), 12);
    const auto first = manager->waitingAttempt(file);
    CPPUNIT_ASSERT_EQUAL(size_t(32), first.size());
    CPPUNIT_ASSERT_EQUAL(250u, manager->reserveChannelRetry(file, first));
    CPPUNIT_ASSERT_EQUAL(0u, manager->reserveChannelRetry(file, first));
    manager->waitForTransfer(file, commit, hash, recvPath.string(), 12);
    CPPUNIT_ASSERT_EQUAL(first, manager->waitingAttempt(file));
    manager->cancel(file);
    CPPUNIT_ASSERT(!manager->consumeChannelRetry(file, first));
    CPPUNIT_ASSERT(manager->waitingAttempt(file).empty());
    manager->waitForTransfer(file, commit, hash, recvPath.string(), 12);
    const auto replacement = manager->waitingAttempt(file);
    CPPUNIT_ASSERT(first != replacement);
    CPPUNIT_ASSERT_EQUAL(0u, manager->reserveChannelRetry(file, first));
    CPPUNIT_ASSERT(!manager->consumeChannelRetry(file, first));
    for (unsigned retry = 0; retry < 8; ++retry) {
        CPPUNIT_ASSERT_EQUAL(250u << std::min(retry, 4u), manager->reserveChannelRetry(file, replacement));
        CPPUNIT_ASSERT_EQUAL(0u, manager->reserveChannelRetry(file, replacement));
        CPPUNIT_ASSERT(manager->consumeChannelRetry(file, replacement));
        CPPUNIT_ASSERT(!manager->consumeChannelRetry(file, replacement));
    }
    CPPUNIT_ASSERT_EQUAL(0u, manager->reserveChannelRetry(file, replacement));
    // A cancellation queued by the old UI visit cannot retire its replacement.
    CPPUNIT_ASSERT(!manager->cancel(file, first));
    CPPUNIT_ASSERT_EQUAL(replacement, manager->waitingAttempt(file));
    CPPUNIT_ASSERT(manager->waitForTransfer(file, commit, hash, recvPath.string(), 12, first).empty());
    CPPUNIT_ASSERT_EQUAL(replacement,
        manager->waitForTransfer(file, commit, hash, recvPath.string(), 12, replacement));
    manager.reset();
    manager = std::make_shared<TransferManager>(aliceId, "", conversation, random);
    const auto resumed = manager->waitingAttempt(file);
    CPPUNIT_ASSERT_EQUAL(size_t(32), resumed.size());
    CPPUNIT_ASSERT(resumed != replacement);
    CPPUNIT_ASSERT(!manager->cancel(file, replacement));
    CPPUNIT_ASSERT(manager->cancel(file, resumed));
    CPPUNIT_ASSERT(manager->waitingAttempt(file).empty());
}

bool
FileTransferTest::compare(const std::string& fileA, const std::string& fileB) const
{
    std::ifstream f1(fileA, std::ifstream::binary | std::ifstream::ate);
    std::ifstream f2(fileB, std::ifstream::binary | std::ifstream::ate);

    if (f1.fail() || f2.fail() || f1.tellg() != f2.tellg()) {
        return false;
    }

    f1.seekg(0, std::ifstream::beg);
    f2.seekg(0, std::ifstream::beg);
    return std::equal(std::istreambuf_iterator<char>(f1.rdbuf()),
                      std::istreambuf_iterator<char>(),
                      std::istreambuf_iterator<char>(f2.rdbuf()));
}

void
FileTransferTest::setUp()
{
    auto actors = load_actors_and_wait_for_announcement("actors/alice-bob-carla.yml");
    aliceId = actors["alice"];
    bobId = actors["bob"];
    carlaId = actors["carla"];
    aliceData = {};
    bobData = {};
    carlaData = {};
}

void
FileTransferTest::tearDown()
{
    for (auto path : {sendPath, recvPath, recv2Path}) {
        std::filesystem::remove(path);
        path += ".tmp";
        std::filesystem::remove(path);
    }
    wait_for_removal_of({aliceId, bobId, carlaId});
}

void
FileTransferTest::connectSignals()
{
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationReady>(
        [&](const std::string& accountId, const std::string& conversationId) {
            if (accountId == aliceId) {
                aliceData.conversationId = conversationId;
            } else if (accountId == bobId) {
                bobData.conversationId = conversationId;
            } else if (accountId == carlaId) {
                carlaData.conversationId = conversationId;
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationRequestReceived>(
        [&](const std::string& accountId,
            const std::string& /* conversationId */,
            std::map<std::string, std::string> /*metadatas*/) {
            if (accountId == aliceId) {
                aliceData.requestReceived = true;
            } else if (accountId == bobId) {
                bobData.requestReceived = true;
            } else if (accountId == carlaId) {
                carlaData.requestReceived = true;
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
        [&](const std::string& accountId, const std::string& conversationId, libjami::SwarmMessage message) {
            std::unique_lock<std::mutex> lk {mtx};
            if (accountId == aliceId) {
                const auto operation = message.body.find(CommitKey::SYBL_OP_V1);
                if (operation != message.body.end() && operation->second == std::string(32, 'd')) {
                    std::string seed;
                    int64_t size = 0;
                    aliceData.ownedSeedVisibleWithMessage = libjami::fileTransferCompleted(
                        aliceId, conversationId, message.body.at("fileId"), seed, size);
                }
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
            if (accountId == aliceId)
                aliceData.removed = true;
            else if (accountId == bobId)
                bobData.removed = true;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::DataTransferSignal::DataTransferEvent>(
        [&](const std::string& accountId,
            const std::string& conversationId,
            const std::string&,
            const std::string& /*fileId*/,
            int code) {
            if (conversationId.empty())
                return;
            if (accountId == aliceId)
                aliceData.code = code;
            else if (accountId == bobId)
                bobData.code = code;
            else if (accountId == carlaId)
                carlaData.code = code;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SybLFileSeedReady>(
        [&](const std::string& account, const std::string&, const std::string&,
            const std::string& commit, const std::string& file, bool ready) {
            std::lock_guard guard(mtx);
            if (account == aliceId && ready) {
                aliceData.seededCommit = commit;
                aliceData.seededFile = file;
            }
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);
}

void FileTransferTest::testRepairOwnedSeed()
{
    connectSignals();
    const auto conversation = libjami::startConversation(aliceId);
    const auto receiver = Manager::instance().getAccount<JamiAccount>(bobId);
    libjami::addConversationMember(aliceId, conversation, receiver->getUsername());
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] { return bobData.requestReceived; }));
    const auto beforeJoin = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, conversation);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] { return aliceData.messages.size() == beforeJoin + 1; }));
    const std::string operation(32, 'd');
    { std::ofstream source(sendPath, std::ios::binary); source << "retained-original-seed"; }
    CPPUNIT_ASSERT_EQUAL(std::string("pending"), libjami::sendSybLFile(
        aliceId, conversation, sendPath.string(), "repair.bin", "", "", "", operation));
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] { return !aliceData.seededCommit.empty(); }));
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] { return aliceData.ownedSeedVisibleWithMessage; }));
    const auto commit = aliceData.seededCommit;
    const auto file = aliceData.seededFile;
    const auto account = Manager::instance().getAccount<JamiAccount>(aliceId);
    const auto seed = account->dataTransfer(conversation)->path(file);
    CPPUNIT_ASSERT(libjami::repairSybLFileSeed(aliceId, conversation, operation, commit, ""));
    CPPUNIT_ASSERT(!libjami::repairSybLFileSeed(aliceId, conversation, std::string(32, 'e'), commit, sendPath.string()));
    CPPUNIT_ASSERT(!libjami::repairSybLFileSeed(bobId, conversation, operation, commit, sendPath.string()));
    CPPUNIT_ASSERT(std::filesystem::remove(seed));
    CPPUNIT_ASSERT(!libjami::repairSybLFileSeed(aliceId, conversation, operation, commit, ""));
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] {
        return !bobData.messages.empty() && bobData.messages.back().id == commit;
    }));
    const std::string receiveAttempt(32, 'f');
    CPPUNIT_ASSERT(libjami::downloadSybLFile(bobId, conversation, commit, file, recvPath.string(), receiveAttempt));
    const auto receiving = receiver->dataTransfer(conversation);
    auto requestedRetry = [&] {
        for (const auto& request : receiving->waitingRequests())
            if (request.fileId == file && request.attemptId == receiveAttempt && request.channelRetries > 0)
                return true;
        return false;
    };
    // Wait for an actual refused channel before restoring the seed, so success
    // proves automatic retry rather than a lucky first connection.
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    while (!requestedRetry() && std::chrono::steady_clock::now() < deadline)
        cv.wait_for(lk, 50ms);
    CPPUNIT_ASSERT(requestedRetry());
    CPPUNIT_ASSERT(libjami::repairSybLFileSeed(aliceId, conversation, operation, commit, sendPath.string()));
    CPPUNIT_ASSERT(compare(seed.string(), sendPath.string()));
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&] {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(compare(recvPath.string(), sendPath.string()));
    CPPUNIT_ASSERT(std::filesystem::remove(seed));
    { std::ofstream source(sendPath, std::ios::trunc); source << "changed"; }
    CPPUNIT_ASSERT(!libjami::repairSybLFileSeed(aliceId, conversation, operation, commit, sendPath.string()));
    CPPUNIT_ASSERT(!std::filesystem::exists(seed));
}

void
FileTransferTest::testConversationFileTransfer()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto carlaAccount = Manager::instance().getAccount<JamiAccount>(carlaId);
    auto carlaUri = carlaAccount->getUsername();
    aliceAccount->trackBuddyPresence(carlaUri, true);

    // Enable carla
    Manager::instance().sendRegister(carlaId, true);
    wait_for_announcement_of(carlaId);

    connectSignals();

    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    libjami::addConversationMember(aliceId, convId, carlaUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 60s, [&]() { return bobData.requestReceived && carlaData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    aliceMsgSize = aliceData.messages.size();
    auto bobMsgSize = bobData.messages.size();
    libjami::acceptConversationRequest(carlaId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return aliceMsgSize + 1 == aliceData.messages.size() && bobMsgSize + 1 == bobData.messages.size();
    }));

    // Send file
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    bobMsgSize = bobData.messages.size();
    auto carlaMsgSize = carlaData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");

    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() {
        return bobData.messages.size() == bobMsgSize + 1 && carlaData.messages.size() == carlaMsgSize + 1;
    }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    libjami::downloadFile(carlaId, convId, id, fileId, recv2Path);

    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() {
        return carlaData.code == static_cast<int>(libjami::DataTransferEventCode::finished)
               && bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
}

void
FileTransferTest::testFileTransferInConversation()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();

    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));

    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];
    // A picked source may change after Send; peers must still get the immutable seed.
    sendFile = std::ofstream(sendPath, std::ios::trunc);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'B');
    sendFile.close();
    libjami::downloadFile(bobId, convId, id, fileId, recvPath);

    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() {
        return aliceData.code == static_cast<int>(libjami::DataTransferEventCode::finished)
               && bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(compare(aliceAccount->dataTransfer(convId)->path(fileId).string(), recvPath.string()));
    CPPUNIT_ASSERT(!compare(sendPath.string(), recvPath.string()));
}

void
FileTransferTest::testVcfFileTransferInConversation()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));

    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];
    libjami::downloadFile(bobId, convId, id, fileId, recvPath);

    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() {
        return aliceData.code == static_cast<int>(libjami::DataTransferEventCode::finished)
               && bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
}

void
FileTransferTest::testBadSha3sumOut()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));

    // Corrupt the actual published seed. The original source is deliberately
    // independent after publication and changing it must not corrupt a transfer.
    const auto publishedFileId = bobData.messages.rbegin()->body.at("fileId");
    const auto publishedSeed = aliceAccount->dataTransfer(convId)->path(publishedFileId);
    CPPUNIT_ASSERT(std::filesystem::is_regular_file(publishedSeed));
    sendFile = std::ofstream(publishedSeed, std::ios::trunc);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'B');
    sendFile.close();

    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];
    libjami::downloadFile(bobId, convId, id, fileId, recvPath);

    CPPUNIT_ASSERT(!cv.wait_for(lk, 45s, [&]() {
        return aliceData.code == static_cast<int>(libjami::DataTransferEventCode::finished)
               || bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
}

void
FileTransferTest::testBadSha3sumIn()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    aliceAccount->noSha3sumVerification(true);
    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));

    // Corrupt the actual published seed. The original source is deliberately
    // independent after publication and changing it must not corrupt a transfer.
    const auto publishedFileId = bobData.messages.rbegin()->body.at("fileId");
    const auto publishedSeed = aliceAccount->dataTransfer(convId)->path(publishedFileId);
    CPPUNIT_ASSERT(std::filesystem::is_regular_file(publishedSeed));
    sendFile = std::ofstream(publishedSeed);
    CPPUNIT_ASSERT(sendFile.is_open());
    // Avoid ASAN error on big alloc   sendFile << std::string("B", 64000);
    sendFile << std::string(64000, 'B');
    sendFile.close();

    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];
    libjami::downloadFile(bobId, convId, id, fileId, recvPath);

    // The file transfer will be sent but refused by bob
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return aliceData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(!cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
}

void
FileTransferTest::testAskToMultipleParticipants()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto carlaAccount = Manager::instance().getAccount<JamiAccount>(carlaId);
    auto aliceUri = aliceAccount->getUsername();
    auto bobUri = bobAccount->getUsername();
    auto carlaUri = carlaAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    libjami::addConversationMember(aliceId, convId, carlaUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 60s, [&]() { return bobData.requestReceived && carlaData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));
    aliceMsgSize = aliceData.messages.size();
    auto bobMsgSize = bobData.messages.size();
    libjami::acceptConversationRequest(carlaId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return aliceMsgSize + 1 == aliceData.messages.size() && bobMsgSize + 1 == bobData.messages.size();
    }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    bobMsgSize = bobData.messages.size();
    auto carlaMsgSize = carlaData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");

    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() {
        return bobData.messages.size() == bobMsgSize + 1 && carlaData.messages.size() == carlaMsgSize + 1;
    }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    libjami::downloadFile(carlaId, convId, id, fileId, recv2Path);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return carlaData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(dhtnet::fileutils::isFile(recv2Path));

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(dhtnet::fileutils::isFile(recvPath));
}

void
FileTransferTest::testCancelInTransfer()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(640000, 'A');
    sendFile.close();

    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::ongoing);
    }));

    libjami::cancelDataTransfer(bobId, convId, fileId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::closed_by_peer);
    }));
    CPPUNIT_ASSERT(!dhtnet::fileutils::isFile(recvPath));
    CPPUNIT_ASSERT(!bobAccount->dataTransfer(convId)->isWaiting(fileId));
}

void
FileTransferTest::testResumeTransferAfterInterruption()
{
    // Create conversation
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    constexpr int64_t totalSize = 12800000;
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(totalSize, 'A');
    sendFile.close();

    // Send file info
    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::ongoing);
    }));

    Manager::instance().sendRegister(aliceId, false);

    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::closed_by_host);
    }));

    std::error_code ec;
    auto receivedSize = std::filesystem::file_size(recvPath + std::string(".tmp"), ec);
    CPPUNIT_ASSERT(!ec);
    CPPUNIT_ASSERT(receivedSize < totalSize);
    CPPUNIT_ASSERT(0 < receivedSize);
    CPPUNIT_ASSERT(bobAccount->dataTransfer(convId)->isWaiting(fileId));

    Manager::instance().sendRegister(aliceId, true);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(!bobAccount->dataTransfer(convId)->isWaiting(fileId));
}

void
FileTransferTest::testDontDownloadExistingFile()
{
    // Create conversation
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    constexpr int64_t totalSize = 128000;
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(totalSize, 'A');
    sendFile.close();

    std::filesystem::copy(sendPath, recvPath);

    // Send file info
    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    CPPUNIT_ASSERT(cv.wait_for(lk, 10s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(!bobAccount->dataTransfer(convId)->isWaiting(fileId));
    CPPUNIT_ASSERT(std::filesystem::file_size(recvPath) == totalSize);
    std::string completedPath;
    int64_t completedSize = -1;
    CPPUNIT_ASSERT(libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    CPPUNIT_ASSERT(completedSize == totalSize);
    // Empty files also finalize from an existing destination, with a durable receipt.
    std::ofstream(sendPath, std::ios::binary | std::ios::trunc).close();
    std::ofstream(recvPath, std::ios::binary | std::ios::trunc).close();
    bobMsgSize = bobData.messages.size();
    bobData.code = 0;
    libjami::sendFile(aliceId, convId, sendPath, "Empty file", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));
    id = bobData.messages.rbegin()->id;
    fileId = bobData.messages.rbegin()->body["fileId"];
    CPPUNIT_ASSERT(libjami::downloadFile(bobId, convId, id, fileId, recvPath));
    CPPUNIT_ASSERT(cv.wait_for(lk, 10s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    CPPUNIT_ASSERT(completedSize == 0 && std::filesystem::file_size(completedPath) == 0);
}

void
FileTransferTest::testTransferInfo()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);
    auto bobUri = bobAccount->getUsername();
    auto aliceUri = aliceAccount->getUsername();
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    libjami::addConversationMember(aliceId, convId, bobUri);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobData.requestReceived; }));

    auto aliceMsgSize = aliceData.messages.size();
    libjami::acceptConversationRequest(bobId, convId);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(640000, 'A');
    sendFile.close();

    auto bobMsgSize = bobData.messages.size();
    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return bobMsgSize + 1 == bobData.messages.size(); }));
    auto id = bobData.messages.rbegin()->id;
    auto fileId = bobData.messages.rbegin()->body["fileId"];

    int64_t totalSize, bytesProgress;
    std::string path;
    CPPUNIT_ASSERT(libjami::fileTransferInfo(bobId, convId, fileId, path, totalSize, bytesProgress)
                   == libjami::DataTransferError::invalid_argument);
    CPPUNIT_ASSERT(bytesProgress == 0);
    CPPUNIT_ASSERT(!std::filesystem::is_regular_file(path));
    // No check for total as not started

    libjami::downloadFile(bobId, convId, id, fileId, recvPath);
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() {
        return bobData.code == static_cast<int>(libjami::DataTransferEventCode::finished);
    }));
    CPPUNIT_ASSERT(libjami::fileTransferInfo(bobId, convId, fileId, path, totalSize, bytesProgress)
                   == libjami::DataTransferError::success);
    CPPUNIT_ASSERT(bytesProgress == 640000);
    CPPUNIT_ASSERT(totalSize == 640000);
    CPPUNIT_ASSERT(dhtnet::fileutils::isFile(path));
    std::string completedPath;
    int64_t completedSize = -1;
    CPPUNIT_ASSERT(libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    CPPUNIT_ASSERT(completedSize == 640000 && completedPath == path);
    // Same bytes in a different object cannot reuse the old completion receipt.
    const auto prior = path + ".receipt-test-prior";
    std::filesystem::rename(path, prior);
    std::filesystem::copy_file(recvPath, path);
    CPPUNIT_ASSERT(!libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    CPPUNIT_ASSERT(completedPath.empty());
    std::filesystem::remove(path);
    std::filesystem::rename(prior, path);
    CPPUNIT_ASSERT(libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    // In-place content changes also invalidate availability.
    std::ofstream modified(path, std::ios::binary | std::ios::trunc);
    modified << std::string(640000, 'B');
    modified.close();
    CPPUNIT_ASSERT(!libjami::fileTransferCompleted(bobId, convId, fileId, completedPath, completedSize));
    CPPUNIT_ASSERT(std::filesystem::file_size(recvPath) == 640000);
}

void
FileTransferTest::testRemoveHardLink()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    connectSignals();
    auto convId = libjami::startConversation(aliceId);

    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !aliceData.conversationId.empty(); }));

    // Send file
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    libjami::sendFile(aliceId, convId, sendPath, std::filesystem::absolute("Display name"), "");

    auto aliceMsgSize = aliceData.messages.size();
    CPPUNIT_ASSERT(cv.wait_for(lk, 45s, [&]() { return aliceMsgSize + 1 == aliceData.messages.size(); }));

    CPPUNIT_ASSERT(libjami::removeConversation(aliceId, convId));
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return aliceData.removed; }));

    auto content = fileutils::loadTextFile(sendPath);
    CPPUNIT_ASSERT(content.find("AAA") != std::string::npos);
}

void
FileTransferTest::testTooLarge()
{
    constexpr int64_t announcedSize = 4;
    auto tempPath = recvPath;
    tempPath += ".tmp";

    libjami::DataTransferInfo info;
    info.path = recvPath.string();
    info.totalSize = announcedSize;
    info.bytesProgress = 3;

    {
        std::ofstream partial(tempPath);
        CPPUNIT_ASSERT(partial.is_open());
        partial << "abc";
    }

    auto channel = std::make_shared<dhtnet::ChannelSocketTest>(Manager::instance().ioContext(),
                                                               dht::PkId(),
                                                               "declared-size-test",
                                                               0);
    auto incoming = std::make_shared<IncomingFile>(channel, info, "file", "interaction", "sha3");
    uint32_t declaredSizeTerminalCode = 0;
    incoming->onFinished(
        [&declaredSizeTerminalCode](uint32_t code) { declaredSizeTerminalCode = code; });
    incoming->process();
    const uint8_t accepted = 'd';
    CPPUNIT_ASSERT_EQUAL(static_cast<ssize_t>(1), channel->cb(&accepted, 1));
    CPPUNIT_ASSERT_EQUAL(announcedSize, incoming->info().bytesProgress);
    const uint8_t overflow = 'e';
    CPPUNIT_ASSERT_EQUAL(static_cast<ssize_t>(-1), channel->cb(&overflow, 1));
    CPPUNIT_ASSERT_EQUAL(announcedSize, incoming->info().bytesProgress);
    channel->shutdown();
    CPPUNIT_ASSERT_EQUAL(uint32_t(libjami::DataTransferEventCode::closed_by_host),
                         declaredSizeTerminalCode);
    CPPUNIT_ASSERT(!std::filesystem::exists(tempPath));
    CPPUNIT_ASSERT(!std::filesystem::exists(recvPath));
    incoming.reset();

    {
        std::ofstream oversized(tempPath, std::ios::trunc);
        CPPUNIT_ASSERT(oversized.is_open());
        oversized << "abcde";
    }
    info.bytesProgress = 5;
    auto invalidResumeChannel = std::make_shared<dhtnet::ChannelSocketTest>(
        Manager::instance().ioContext(), dht::PkId(), "invalid-resume-test", 0);
    auto invalidResume =
        std::make_shared<IncomingFile>(invalidResumeChannel, info, "file", "interaction", "sha3");
    CPPUNIT_ASSERT(!std::filesystem::exists(tempPath));
    CPPUNIT_ASSERT(!std::filesystem::exists(recvPath));
    invalidResume.reset();

    auto profilePath = recvPath;
    profilePath += ".profile";
    auto profileTempPath = profilePath;
    profileTempPath += ".tmp";
    info.path = profilePath.string();
    info.totalSize = 0;
    info.bytesProgress = 0;
    channel = std::make_shared<dhtnet::ChannelSocketTest>(Manager::instance().ioContext(),
                                                          dht::PkId(),
                                                          "profile-size-test",
                                                          0);
    incoming = std::make_shared<IncomingFile>(channel, info, "profile.vcf", "", "sha3");
    uint32_t terminalCode = 0;
    incoming->onFinished([&terminalCode](uint32_t code) { terminalCode = code; });
    incoming->process();
    std::vector<uint8_t> profile(PROFILE_VCARD_MAX_BYTES, 'p');
    CPPUNIT_ASSERT_EQUAL(static_cast<ssize_t>(PROFILE_VCARD_MAX_BYTES),
                         channel->cb(profile.data(), profile.size()));
    const uint8_t extra = 'x';
    CPPUNIT_ASSERT_EQUAL(static_cast<ssize_t>(-1), channel->cb(&extra, 1));
    CPPUNIT_ASSERT_EQUAL(PROFILE_VCARD_MAX_BYTES, incoming->info().bytesProgress);
    channel->shutdown();
    CPPUNIT_ASSERT_EQUAL(uint32_t(libjami::DataTransferEventCode::closed_by_host), terminalCode);
    CPPUNIT_ASSERT(!std::filesystem::exists(profileTempPath));
    CPPUNIT_ASSERT(!std::filesystem::exists(profilePath));
}

void
FileTransferTest::testReceiveBelowSearchOnlyAncestor()
{
#ifndef _WIN32
    // Android grants apps search, not read, on "/" and system ancestors of
    // their data directory. Receives must not require reading any ancestor.
    const auto root = std::filesystem::current_path() / "search-only-ancestor";
    const auto inner = root / "inner" / "profiles";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(inner);
    const auto link = std::filesystem::current_path() / "search-only-ancestor-link";
    std::filesystem::remove(link);
    std::filesystem::create_directory_symlink(root / "inner", link);
    struct Restore {
        std::filesystem::path root, link;
        ~Restore() {
            std::error_code ec;
            std::filesystem::permissions(root, std::filesystem::perms::owner_all, ec);
            std::filesystem::remove_all(root, ec);
            std::filesystem::remove(link, ec);
        }
    } restore {root, link};
    std::filesystem::permissions(root, std::filesystem::perms::owner_exec);
    std::error_code listError;
    std::filesystem::directory_iterator unreadable(root, listError);
    CPPUNIT_ASSERT_MESSAGE("run permission tests unprivileged", listError);

    const auto receive = [](const std::filesystem::path& target, const char* name) {
        libjami::DataTransferInfo info;
        info.path = target.string();
        info.totalSize = 0;
        info.bytesProgress = 0;
        auto channel = std::make_shared<dhtnet::ChannelSocketTest>(
            Manager::instance().ioContext(), dht::PkId(), name, 0);
        auto incoming = std::make_shared<IncomingFile>(channel, info, "profile.vcf", "", "");
        uint32_t terminalCode = 0;
        incoming->onFinished([&terminalCode](uint32_t code) { terminalCode = code; });
        incoming->process();
        const std::string vcard = "BEGIN:VCARD\nFN:Bob\nEND:VCARD\n";
        channel->cb(reinterpret_cast<const uint8_t*>(vcard.data()), vcard.size());
        channel->shutdown();
        return terminalCode;
    };

    const auto received = inner / "received";
    CPPUNIT_ASSERT_EQUAL(uint32_t(libjami::DataTransferEventCode::finished),
                         receive(received, "search-only-ancestor-test"));
    CPPUNIT_ASSERT(std::filesystem::is_regular_file(received));
    auto tempPath = received;
    tempPath += ".tmp";
    CPPUNIT_ASSERT(!std::filesystem::exists(tempPath));

    // A symlinked ancestor is still refused although ancestors are not read.
    const auto viaLink = link / "profiles" / "linked";
    CPPUNIT_ASSERT_EQUAL(uint32_t(libjami::DataTransferEventCode::closed_by_host),
                         receive(viaLink, "symlinked-ancestor-test"));
    CPPUNIT_ASSERT(!std::filesystem::exists(inner / "linked"));
    CPPUNIT_ASSERT(!std::filesystem::exists(inner / "linked.tmp"));

    // Android 11+ app data isolation exposes /data/user/0 as a symlink in a
    // system directory the app cannot modify; such links remain usable.
    std::error_code linkError;
    if (std::filesystem::is_symlink("/lib", linkError)) {
        struct stat root {};
        CPPUNIT_ASSERT(::stat("/", &root) == 0);
        CPPUNIT_ASSERT_MESSAGE("run permission tests unprivileged", root.st_uid != ::geteuid());
        received_seed::Directory systemLink("/lib");
        CPPUNIT_ASSERT(systemLink.valid());
        struct stat opened {}, resolved {};
        CPPUNIT_ASSERT(::fstat(systemLink.handle(), &opened) == 0);
        CPPUNIT_ASSERT(::stat("/lib", &resolved) == 0);
        CPPUNIT_ASSERT(opened.st_dev == resolved.st_dev && opened.st_ino == resolved.st_ino);
        CPPUNIT_ASSERT(systemLink.current());
    }
#endif
}

void
FileTransferTest::testPublicationFailurePreservesDestination()
{
    const auto destination = std::filesystem::current_path() / "publication-occupied";
    const auto partial = std::filesystem::path(destination.string() + ".tmp");
    CPPUNIT_ASSERT(!std::filesystem::exists(destination));
    CPPUNIT_ASSERT(!std::filesystem::exists(partial));
    struct Cleanup {
        std::filesystem::path destination, partial;
        ~Cleanup() {
            std::error_code ec;
            std::filesystem::remove(destination, ec);
            std::filesystem::remove(partial, ec);
        }
    } cleanup {destination, partial};
    libjami::DataTransferInfo info;
    info.path = destination.string();
    info.totalSize = 0;
    info.bytesProgress = 0;
    auto channel = std::make_shared<dhtnet::ChannelSocketTest>(
        Manager::instance().ioContext(), dht::PkId(), "publication-occupied-test", 0);
    auto incoming = std::make_shared<IncomingFile>(channel, info, "profile.vcf", "", "");
    uint32_t terminal = 0;
    incoming->onFinished([&terminal](uint32_t code) { terminal = code; });
    incoming->process();
    const std::string received = "BEGIN:VCARD\nFN:received\nEND:VCARD\n";
    channel->cb(reinterpret_cast<const uint8_t*>(received.data()), received.size());
    // Another writer claims the final name after receive started.
    { std::ofstream output(destination); output << "other"; }
    channel->shutdown();
    CPPUNIT_ASSERT_EQUAL(uint32_t(libjami::DataTransferEventCode::closed_by_host), terminal);
    incoming.reset();
    const auto read = [](const std::filesystem::path& path) {
        std::ifstream input(path);
        return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    };
    CPPUNIT_ASSERT_EQUAL(std::string("other"), read(destination));
    CPPUNIT_ASSERT_EQUAL(received, read(partial));
    // Refusal leaves the retained bytes usable for an explicit safe retry.
    std::filesystem::remove(destination);
    received_seed::File retry(partial, received_seed::File::Mode::append);
    CPPUNIT_ASSERT(retry.valid());
    CPPUNIT_ASSERT(retry.publishTo(destination));
    CPPUNIT_ASSERT_EQUAL(received, read(destination));
}

void
FileTransferTest::testDeleteFile()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    auto convId = libjami::startConversation(aliceId);

    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    bool conversationReady = false;
    std::string iid, tid;
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
        [&](const std::string& accountId, const std::string& /* conversationId */, libjami::SwarmMessage message) {
            if (message.type == CommitType::DATA_TRANSFER) {
                if (accountId == aliceId) {
                    iid = message.id;
                    tid = message.body[CommitKey::TID];
                }
            }
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::ConversationReady>(
        [&](const std::string& accountId, const std::string& /* conversationId */) {
            if (accountId == bobId) {
                conversationReady = true;
                cv.notify_one();
            }
        }));
    bool messageUpdated = false;
    confHandlers.insert(libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageUpdated>(
        [&](const std::string& accountId, const std::string& /* conversationId */, libjami::SwarmMessage message) {
            if (accountId == aliceId && message.type == CommitType::DATA_TRANSFER
                && message.body[CommitKey::TID].empty()) {
                messageUpdated = true;
            }
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);

    // Create file to send
    std::ofstream sendFile(sendPath);
    CPPUNIT_ASSERT(sendFile.is_open());
    sendFile << std::string(64000, 'A');
    sendFile.close();

    libjami::sendFile(aliceId, convId, sendPath, "Display name", "");

    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !iid.empty(); }));
    auto dataPath = fileutils::get_data_dir() / aliceId / "conversation_data" / convId;
    CPPUNIT_ASSERT(dhtnet::fileutils::isFile(dataPath / fmt::format("{}_{}", iid, tid)));

    // Delete file
    libjami::sendMessage(aliceId, convId, ""s, iid, 1);

    // Verify message is updated
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return messageUpdated; }));
    // Verify file is deleted
    CPPUNIT_ASSERT(!dhtnet::fileutils::isFile(dataPath / fmt::format("{}_{}", iid, tid)));

    // Now test with a file that has an extension
    iid.clear();
    tid.clear();
    messageUpdated = false;

    auto sendPathWithExt = sendPath;
    sendPathWithExt += ".log";
    std::ofstream sendFile2(sendPathWithExt);
    CPPUNIT_ASSERT(sendFile2.is_open());
    sendFile2 << std::string(64000, 'A');
    sendFile2.close();

    // The display name is usually the same as the original file name, but the libjami::sendFile API
    // allows setting it to a custom value. The file extension used internally by the daemon should
    // always match the one of the display name, even if it differs from the original file.
    libjami::sendFile(aliceId, convId, sendPathWithExt, "Display name.txt", "");

    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return !iid.empty(); }));
    CPPUNIT_ASSERT(dhtnet::fileutils::isFile(dataPath / fmt::format("{}_{}.txt", iid, tid)));

    // Delete file
    libjami::sendMessage(aliceId, convId, ""s, iid, 1);

    // Verify message is updated
    CPPUNIT_ASSERT(cv.wait_for(lk, 30s, [&]() { return messageUpdated; }));
    // Verify file is deleted
    CPPUNIT_ASSERT(!dhtnet::fileutils::isFile(dataPath / fmt::format("{}_{}.txt", iid, tid)));

    std::filesystem::remove(sendPathWithExt);
    libjami::unregisterSignalHandlers();
    std::this_thread::sleep_for(5s);
}

} // namespace test
} // namespace jami

// Startup is deliberately tested across separate processes: fini() joins the
// daemon's process-global worker pools and is not a supported restart boundary.
int main(int argc, char** argv)
{
    if (argc == 2 && (std::string(argv[1]) == "--activation-seed" ||
                      std::string(argv[1]) == "--activation-probe")) {
        const std::string mode(argv[1]);
        try {
            const bool probe = mode == "--activation-probe";
            CPPUNIT_ASSERT(libjami::init(libjami::InitFlag(
                probe ? libjami::LIBJAMI_FLAG_START_INACTIVE : 0)));
            CPPUNIT_ASSERT(libjami::start("jami-sample.yml"));
            if (!probe) {
                const auto actors = load_actors_and_wait_for_announcement(
                    "actors/alice-bob-carla.yml");
                CPPUNIT_ASSERT_EQUAL(size_t(3), actors.size());
                for (const auto& [name, id] : actors)
                    CPPUNIT_ASSERT_EQUAL(std::string("true"),
                        libjami::getAccountDetails(id).at("Account.enable"));
            } else {
                const auto accounts = libjami::getAccountList();
                CPPUNIT_ASSERT_EQUAL(size_t(3), accounts.size());
                for (const auto& id : accounts) {
                    CPPUNIT_ASSERT_EQUAL(std::string("true"),
                        libjami::getAccountDetails(id).at("Account.enable"));
                    CPPUNIT_ASSERT_EQUAL(std::string("false"),
                        libjami::getVolatileAccountDetails(id).at("Account.active"));
                    CPPUNIT_ASSERT(libjami::getVolatileAccountDetails(id)
                        .at("Account.registrationStatus") != "REGISTERED");
                    libjami::sendRegister(id, true);
                    CPPUNIT_ASSERT_EQUAL(std::string("false"),
                        libjami::getVolatileAccountDetails(id).at("Account.active"));
                }
                libjami::setAccountActive(accounts.front(), true, false);
                CPPUNIT_ASSERT_EQUAL(std::string("true"),
                    libjami::getVolatileAccountDetails(accounts.front()).at("Account.active"));
                for (size_t i = 1; i < accounts.size(); ++i)
                    CPPUNIT_ASSERT_EQUAL(std::string("false"),
                        libjami::getVolatileAccountDetails(accounts[i]).at("Account.active"));
            }
            // Model process loss after an explicitly saved configuration. This
            // exercises startup recovery independently of UPnP shutdown, which
            // has its own lifecycle tests and must not keep this fixture alive.
            jami::Manager::instance().saveConfig();
            std::cout << mode << " PASS\n" << std::flush;
            std::_Exit(0);
        } catch (const std::exception& error) {
            std::cerr << "Activation barrier assertion failed: " << error.what() << '\n';
            std::cerr << std::flush;
            std::_Exit(1);
        }
    }
    auto& registry = CppUnit::TestFactoryRegistry::getRegistry(jami::test::FileTransferTest::name());
    CppUnit::TextUi::TestRunner runner;
    runner.addTest(registry.makeTest());
    return runner.run(argc > 1 ? argv[1] : "") ? 0 : 1;
}
