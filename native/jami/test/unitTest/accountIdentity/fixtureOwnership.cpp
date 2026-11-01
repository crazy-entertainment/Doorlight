/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <vector>
#include "common.h"
#include "jami.h"
#include "configurationmanager_interface.h"
#include <cppunit/Exception.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <stdexcept>

static void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

static std::vector<std::string> accounts()
{
    auto result = libjami::getAccountList();
    std::sort(result.begin(), result.end());
    return result;
}

int main(int argc, char** argv)
{
    const std::string mode = argc == 2 ? argv[1] : "timeout";
    bool initialized = false;
    try {
        require(libjami::init(libjami::InitFlag(libjami::LIBJAMI_FLAG_START_INACTIVE)), "Daemon init failed");
        initialized = true;
        require(libjami::start("jami-sample.yml"), "Daemon start failed");
        const auto retained = libjami::addAccount({{"Account.type", "RING"}, {"Account.enable", "false"}});
        require(!retained.empty(), "Retained fixture identity was not created");
        const auto before = accounts();
        if (mode == "timeout") {
            std::ofstream fixture("never-announced.yml");
            fixture << "default-account:\n  type: RING\n  enable: false\naccounts:\n  first: {}\n  second: {}\n";
            fixture.close();
            require(fixture.good(), "Could not write isolated actor fixture");
            bool asserted = false;
            try { (void) load_actors_and_wait_for_announcement("never-announced.yml"); }
            catch (const CppUnit::Exception&) { asserted = true; }
            require(asserted, "Announcement timeout assertion was lost");
            require(accounts() == before, "Timed-out actor admission leaked new accounts");
        } else {
            require(mode == "removal", "Expected timeout or removal mode");
            wait_for_removal_of(std::vector<std::string> {"previously-removed-fixture", ""});
            require(accounts() == before, "Removing absent actors touched another account");
        }
        wait_for_removal_of({retained, retained});
        require(accounts().empty(), "Exact actor removal failed");
        libjami::fini();
        initialized = false;
        std::cout << "Fixture " << mode << " keeps exact account ownership and the original assertion\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        if (initialized) libjami::fini();
        return 1;
    }
}
