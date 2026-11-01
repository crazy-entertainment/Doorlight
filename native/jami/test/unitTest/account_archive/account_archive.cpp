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

#include "manager.h"
#include "jamidht/conversationrepository.h"
#include "jamidht/gitserver.h"
#include "jamidht/jamiaccount.h"
#include "../../test_runner.h"
#include "archiver.h"
#include "base64.h"
#include "jami.h"
#include "fileutils.h"
#include "account_const.h"
#include "account_schema.h"
#include "common.h"

#include <dhtnet/connectionmanager.h>

#include <cppunit/TestAssert.h>
#include <cppunit/TestFixture.h>
#include <cppunit/extensions/HelperMacros.h>

#include <git2.h>
#include <condition_variable>
#include <string>
#include <fstream>
#include <streambuf>
#include <filesystem>

using namespace std::string_literals;
using namespace std::literals::chrono_literals;
using namespace libjami::Account;

namespace jami {
namespace test {

class AccountArchiveTest : public CppUnit::TestFixture
{
public:
    AccountArchiveTest()
    {
        // Init daemon
        libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_DEBUG | libjami::LIBJAMI_FLAG_CONSOLE_LOG));
        if (not Manager::instance().initialized)
            CPPUNIT_ASSERT(libjami::start("dring-sample.yml"));
    }
    ~AccountArchiveTest() { libjami::fini(); }
    static std::string name() { return "AccountArchive"; }
    void setUp();
    void tearDown();

    std::string aliceId;
    std::string bobId;
    std::string bob2Id;

    std::map<std::string, std::shared_ptr<libjami::CallbackWrapperBase>> confHandlers;
    std::mutex mtx;
    std::unique_lock<std::mutex> lk {mtx};
    std::condition_variable cv;
    bool aliceReady = false;

private:
    void testExportImportNoPassword();
    void testExportImportNoPasswordDoubleGunzip();
    void testExportImportPassword();
    void testExportImportPasswordDoubleGunzip();
    void testAuthenticatedImportEnableMerge();
    void testSnapshotExportCredentials();
    // void testExportDht();
    // void testExportDhtWrongPassword();
    void testChangePassword();
    void testChangeDhtPort();

    CPPUNIT_TEST_SUITE(AccountArchiveTest);
    CPPUNIT_TEST(testExportImportNoPassword);
    CPPUNIT_TEST(testExportImportNoPasswordDoubleGunzip);
    CPPUNIT_TEST(testExportImportPassword);
    CPPUNIT_TEST(testExportImportPasswordDoubleGunzip);
    CPPUNIT_TEST(testAuthenticatedImportEnableMerge);
    CPPUNIT_TEST(testSnapshotExportCredentials);
    // CPPUNIT_TEST(testExportDht);
    // CPPUNIT_TEST(testExportDhtWrongPassword);
    CPPUNIT_TEST(testChangePassword);
    CPPUNIT_TEST(testChangeDhtPort);
    CPPUNIT_TEST_SUITE_END();
};

CPPUNIT_TEST_SUITE_NAMED_REGISTRATION(AccountArchiveTest, AccountArchiveTest::name());

void
AccountArchiveTest::setUp()
{
    auto actors = load_actors_and_wait_for_announcement("actors/alice-bob-password.yml");
    aliceId = actors["alice"];
    bobId = actors["bob"];

    confHandlers.insert(libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
        [&](const std::string& accountId, const std::map<std::string, std::string>& details) {
            if (accountId != aliceId) {
                return;
            }
            try {
                aliceReady |= accountId == aliceId
                              && details.at(jami::Conf::CONFIG_ACCOUNT_REGISTRATION_STATUS) == "REGISTERED"
                              && details.at(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED) == "true";
            } catch (const std::out_of_range&) {
            }
            cv.notify_one();
        }));
    libjami::registerSignalHandlers(confHandlers);
}

void
AccountArchiveTest::tearDown()
{
    if (!bob2Id.empty())
        wait_for_removal_of({aliceId, bob2Id, bobId});
    else
        wait_for_removal_of({aliceId, bobId});
}

void
AccountArchiveTest::testExportImportNoPassword()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);

    CPPUNIT_ASSERT(aliceAccount->exportArchive("test.gz"));

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "test.gz";

    auto accountId = jami::Manager::instance().addAccount(details);
    wait_for_announcement_of(accountId);
    auto alice2Account = Manager::instance().getAccount<JamiAccount>(accountId);
    CPPUNIT_ASSERT(alice2Account->getUsername() == aliceAccount->getUsername());
    std::remove("test.gz");
    wait_for_removal_of(accountId);
}

void
AccountArchiveTest::testExportImportNoPasswordDoubleGunzip()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);

    CPPUNIT_ASSERT(aliceAccount->exportArchive("test.gz"));
    auto dat = fileutils::loadFile("test.gz");
    archiver::compressGzip(dat, "test.gz");

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "test.gz";

    auto accountId = jami::Manager::instance().addAccount(details);
    wait_for_announcement_of(accountId);
    auto alice2Account = Manager::instance().getAccount<JamiAccount>(accountId);
    CPPUNIT_ASSERT(alice2Account->getUsername() == aliceAccount->getUsername());
    std::remove("test.gz");
    wait_for_removal_of(accountId);
}

void
AccountArchiveTest::testExportImportPassword()
{
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);

    CPPUNIT_ASSERT(bobAccount->exportArchive("test.gz", "password", "test"));

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "test.gz";
    details[ConfProperties::ARCHIVE_PASSWORD] = "test";

    auto accountId = jami::Manager::instance().addAccount(details);
    wait_for_announcement_of(accountId);
    auto bob2Account = Manager::instance().getAccount<JamiAccount>(accountId);
    CPPUNIT_ASSERT(bob2Account->getUsername() == bobAccount->getUsername());
    std::remove("test.gz");
    wait_for_removal_of(accountId);
}

void
AccountArchiveTest::testExportImportPasswordDoubleGunzip()
{
    auto bobAccount = Manager::instance().getAccount<JamiAccount>(bobId);

    CPPUNIT_ASSERT(bobAccount->exportArchive("test.gz", "password", "test"));
    auto dat = fileutils::loadFile("test.gz");
    archiver::compressGzip(dat, "test.gz");

    std::map<std::string, std::string> details = libjami::getAccountTemplate("RING");
    details[ConfProperties::ARCHIVE_PATH] = "test.gz";
    details[ConfProperties::ARCHIVE_PASSWORD] = "test";

    auto accountId = jami::Manager::instance().addAccount(details);
    wait_for_announcement_of(accountId);
    auto bob2Account = Manager::instance().getAccount<JamiAccount>(accountId);
    CPPUNIT_ASSERT(bob2Account->getUsername() == bobAccount->getUsername());
    std::remove("test.gz");
    wait_for_removal_of(accountId);
}

void
AccountArchiveTest::testAuthenticatedImportEnableMerge()
{
    const auto enabledAfterAuthentication = [](bool locallyEnabled, bool archivedEnabled) {
        JamiAccountConfig config;
        config.enabled = locallyEnabled;
        config.fromAuthenticatedMap({{Conf::CONFIG_ACCOUNT_ENABLE, archivedEnabled ? "true" : "false"}});
        return config.enabled;
    };

    CPPUNIT_ASSERT(!enabledAfterAuthentication(false, true));
    CPPUNIT_ASSERT(!enabledAfterAuthentication(true, false));
    CPPUNIT_ASSERT(enabledAfterAuthentication(true, true));
}

void
AccountArchiveTest::testSnapshotExportCredentials()
{
    const auto liveArchive = fileutils::get_data_dir() / aliceId / "archive.gz";
    const auto liveBefore = fileutils::loadFile(liveArchive);
    const auto destination = std::filesystem::path("snapshot-export.gz");

    CPPUNIT_ASSERT(!libjami::exportToFileWithCredentials(aliceId,
                                                         liveArchive.string(),
                                                         "password",
                                                         "",
                                                         "password",
                                                         "must not replace live"));
    CPPUNIT_ASSERT(liveBefore == fileutils::loadFile(liveArchive));

    const auto liveAlias = liveArchive.parent_path() / "archive-export-alias.gz";
    std::error_code aliasError;
    std::filesystem::create_hard_link(liveArchive, liveAlias, aliasError);
    CPPUNIT_ASSERT(!aliasError);
    CPPUNIT_ASSERT(!libjami::exportToFileWithCredentials(aliceId,
                                                         liveAlias.string(),
                                                         "password",
                                                         "",
                                                         "password",
                                                         "must not replace alias"));
    CPPUNIT_ASSERT(liveBefore == fileutils::loadFile(liveArchive));
    std::filesystem::remove(liveAlias);

    CPPUNIT_ASSERT(libjami::exportToFileWithCredentials(aliceId,
                                                        destination.string(),
                                                        "password",
                                                        "",
                                                        "password",
                                                        "backup password"));
    CPPUNIT_ASSERT(liveBefore == fileutils::loadFile(liveArchive));
    CPPUNIT_ASSERT(libjami::isPasswordValid(aliceId, ""));
    CPPUNIT_ASSERT(!fileutils::readArchive(destination, "password", "backup password").data.empty());
    CPPUNIT_ASSERT_THROW(fileutils::readArchive(destination, "password", "wrong"), std::exception);

    const auto destinationBefore = fileutils::loadFile(destination);
    CPPUNIT_ASSERT(!libjami::exportToFileWithCredentials(aliceId,
                                                         destination.string(),
                                                         "password",
                                                         "wrong input",
                                                         "password",
                                                         "replacement password"));
    CPPUNIT_ASSERT(destinationBefore == fileutils::loadFile(destination));
    CPPUNIT_ASSERT(liveBefore == fileutils::loadFile(liveArchive));
    CPPUNIT_ASSERT(!fileutils::readArchive(destination, "password", "backup password").data.empty());

    fileutils::setArchiveWriteFailpointForTesting(fileutils::ArchiveWriteFailpoint::BeforeReplace);
    CPPUNIT_ASSERT(!libjami::exportToFileWithCredentials(aliceId,
                                                         destination.string(),
                                                         "password",
                                                         "",
                                                         "password",
                                                         "replacement password"));
    CPPUNIT_ASSERT(destinationBefore == fileutils::loadFile(destination));
    CPPUNIT_ASSERT(liveBefore == fileutils::loadFile(liveArchive));
    CPPUNIT_ASSERT(!fileutils::readArchive(destination, "password", "backup password").data.empty());

    std::filesystem::remove(destination);
}

void
AccountArchiveTest::testChangePassword()
{
    const auto aliceArchive = fileutils::get_data_dir() / aliceId / "archive.gz";
    const auto original = fileutils::loadFile(aliceArchive);

    // A crash/failure after the sibling temporary file is durable but before
    // replacement must preserve the old archive byte-for-byte and keep its
    // password authoritative.
    fileutils::setArchiveWriteFailpointForTesting(fileutils::ArchiveWriteFailpoint::BeforeReplace);
    CPPUNIT_ASSERT(!libjami::changeAccountPassword(aliceId, "", "interrupted"));
    CPPUNIT_ASSERT(original == fileutils::loadFile(aliceArchive));
    CPPUNIT_ASSERT(libjami::isPasswordValid(aliceId, ""));
    CPPUNIT_ASSERT(!libjami::isPasswordValid(aliceId, "interrupted"));

    // Test incorrect password, should fail
    CPPUNIT_ASSERT(!libjami::changeAccountPassword(aliceId, "wrong", "new"));
    // Test correct password, should succeed
    CPPUNIT_ASSERT(libjami::changeAccountPassword(aliceId, "", "new"));
    CPPUNIT_ASSERT(libjami::isPasswordValid(aliceId, "new"));
    CPPUNIT_ASSERT(!libjami::isPasswordValid(aliceId, ""));
    // Now it should fail
    CPPUNIT_ASSERT(!libjami::changeAccountPassword(aliceId, "", "new"));
    // Remove password again (should succeed)
    CPPUNIT_ASSERT(libjami::changeAccountPassword(aliceId, "new", ""));
    CPPUNIT_ASSERT(libjami::isPasswordValid(aliceId, ""));
}

void
AccountArchiveTest::testChangeDhtPort()
{
    auto aliceAccount = Manager::instance().getAccount<JamiAccount>(aliceId);

    std::map<std::string, std::string> newDetails;
    newDetails[libjami::Account::ConfProperties::DHT_PORT] = "1412";
    aliceReady = false;
    libjami::setAccountDetails(aliceId, newDetails);
    cv.wait_for(lk, 20s, [&] { return aliceReady; });

    CPPUNIT_ASSERT(aliceAccount->dht()->getBoundPort() == 1412);

    newDetails[libjami::Account::ConfProperties::DHT_PORT] = "1413";
    aliceReady = false;
    libjami::setAccountDetails(aliceId, newDetails);
    cv.wait_for(lk, 20s, [&] { return aliceReady; });

    CPPUNIT_ASSERT(aliceAccount->dht()->getBoundPort() == 1413);
}

} // namespace test
} // namespace jami

CORE_TEST_RUNNER(jami::test::AccountArchiveTest::name())
