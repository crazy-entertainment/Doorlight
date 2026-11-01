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
#include <future>
#include <string>
#include <fstream>
#include <streambuf>

#include "manager.h"
#include "jamidht/archive_account_manager.h"
#include "jamidht/jamiaccount.h"
#include "../../test_runner.h"
#include "jami.h"
#include "fileutils.h"
#include "account_const.h"
#include "common.h"

using namespace std::string_literals;
using namespace libjami::Account;

namespace jami {
namespace test {

class RevokeTest : public CppUnit::TestFixture
{
public:
    RevokeTest()
    {
        // Init daemon
        libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_DEBUG | libjami::LIBJAMI_FLAG_CONSOLE_LOG));
        if (not Manager::instance().initialized)
            CPPUNIT_ASSERT(libjami::start("dring-sample.yml"));
    }
    ~RevokeTest() { libjami::fini(); }
    static std::string name() { return "Revoke"; }
    void setUp();
    void tearDown();

    std::string aliceId;
    std::string bobId;

private:
    void testRevokeDevice();
    void testPasswordChangeSerializedWithRevoke();
    void testRevokeInvalidDevice();

    CPPUNIT_TEST_SUITE(RevokeTest);
    CPPUNIT_TEST(testRevokeDevice);
    CPPUNIT_TEST(testPasswordChangeSerializedWithRevoke);
    CPPUNIT_TEST(testRevokeInvalidDevice);
    CPPUNIT_TEST_SUITE_END();
};

CPPUNIT_TEST_SUITE_NAMED_REGISTRATION(RevokeTest, RevokeTest::name());

void
RevokeTest::setUp()
{
    auto actors = load_actors_and_wait_for_announcement("actors/alice-bob-password.yml");
    aliceId = actors["alice"];
    bobId = actors["bob"];
}

void
RevokeTest::tearDown()
{
    wait_for_removal_of({aliceId, bobId});
}

void
RevokeTest::testRevokeDevice()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);

    CPPUNIT_ASSERT(aliceAccount->exportArchive("test.gz"));

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "test.gz";

    std::mutex mtx;
    std::unique_lock lk {mtx};
    std::condition_variable cv;
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    auto deviceRevoked = false;
    auto knownChanged = false;
    std::string alice2Device;
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::DeviceRevocationEnded>(
        [&](const std::string& accountId, const std::string& deviceId, int status) {
            if (accountId == aliceId && deviceId == alice2Device && status == 0)
                deviceRevoked = true;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::KnownDevicesChanged>(
        [&](const std::string& accountId, auto devices) {
            if (accountId == aliceId && devices.size() == 2)
                knownChanged = true;
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);
    auto alice2Id = jami::Manager::instance().addAccount(details);
    auto alice2Account = Manager::instance().getAccount<JamiAccount>(alice2Id);
    CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(60), [&] { return knownChanged; }));
    alice2Device = std::string(alice2Account->currentDeviceId());
    aliceAccount->revokeDevice(alice2Device);
    CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(10), [&] { return deviceRevoked; }));

    std::remove("test.gz");
    wait_for_removal_of(alice2Id);
}

void
RevokeTest::testPasswordChangeSerializedWithRevoke()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);
    CPPUNIT_ASSERT(aliceAccount->exportArchive("revoke-serialization.gz"));

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "revoke-serialization.gz";

    std::mutex mtx;
    std::unique_lock lk {mtx};
    std::condition_variable cv;
    bool knownChanged = false;
    bool revokeFinished = false;
    int revokeStatus = -1;
    bool transactionEntered = false;
    bool releaseTransaction = false;
    std::string alice2Device;
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::KnownDevicesChanged>(
        [&](const std::string& accountId, auto devices) {
            if (accountId == aliceId && devices.size() == 2)
                knownChanged = true;
            cv.notify_one();
        }));
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::DeviceRevocationEnded>(
        [&](const std::string& accountId, const std::string& deviceId, int status) {
            if (accountId == aliceId && deviceId == alice2Device) {
                revokeFinished = true;
                revokeStatus = status;
            }
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);

    auto alice2Id = jami::Manager::instance().addAccount(details);
    auto alice2Account = Manager::instance().getAccount<JamiAccount>(alice2Id);
    CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(60), [&] { return knownChanged; }));
    alice2Device = std::string(alice2Account->currentDeviceId());

    setArchiveRevokeTransactionHookForTesting([&] {
        std::unique_lock hookLock {mtx};
        transactionEntered = true;
        cv.notify_one();
        cv.wait(hookLock, [&] { return releaseTransaction; });
    });
    aliceAccount->revokeDevice(alice2Device);
    const auto entered = cv.wait_for(lk, std::chrono::seconds(10), [&] { return transactionEntered; });
    if (!entered)
        setArchiveRevokeTransactionHookForTesting({});
    CPPUNIT_ASSERT(entered);

    std::promise<void> passwordChangeStarted;
    auto passwordChange = std::async(std::launch::async, [&] {
        passwordChangeStarted.set_value();
        return libjami::changeAccountPassword(aliceId, "", "serialized");
    });
    passwordChangeStarted.get_future().wait();
    const auto passwordChangeWasBlocked = passwordChange.wait_for(std::chrono::milliseconds(100))
                                          == std::future_status::timeout;
    releaseTransaction = true;
    lk.unlock();
    cv.notify_one();

    const auto passwordChanged = passwordChange.get();
    lk.lock();
    CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(10), [&] { return revokeFinished; }));
    CPPUNIT_ASSERT_EQUAL(0, revokeStatus);
    CPPUNIT_ASSERT(passwordChangeWasBlocked);
    CPPUNIT_ASSERT(passwordChanged);
    CPPUNIT_ASSERT(libjami::isPasswordValid(aliceId, "serialized"));
    CPPUNIT_ASSERT(!libjami::isPasswordValid(aliceId, ""));

    std::remove("revoke-serialization.gz");
    wait_for_removal_of(alice2Id);
}

void
RevokeTest::testRevokeInvalidDevice()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);

    std::mutex mtx;
    std::unique_lock lk {mtx};
    std::condition_variable cv;
    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    auto revokeFailed = false;
    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::DeviceRevocationEnded>(
        [&](const std::string& accountId, const std::string& deviceId, int status) {
            if (accountId == aliceId && deviceId == "foo" && status == 2)
                revokeFailed = true;
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);
    aliceAccount->revokeDevice("foo");
    CPPUNIT_ASSERT(cv.wait_for(lk, std::chrono::seconds(10), [&] { return revokeFailed; }));
}

} // namespace test
} // namespace jami

CORE_TEST_RUNNER(jami::test::RevokeTest::name())
