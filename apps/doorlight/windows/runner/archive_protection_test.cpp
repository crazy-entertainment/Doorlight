#ifdef NDEBUG
#undef NDEBUG
#endif

#include "archive_protection.h"

#include <cassert>
#include <string>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {

const std::string kAccount = "account";
const std::string kSecret(64, 'a');

void ProtectedArchiveAlwaysProvesSecretWithoutRewrite() {
  std::vector<std::string> calls;
  const sybl::archive::ArchiveProtectionCallbacks callbacks{
      [&](const std::string &, const std::string &) {
        calls.push_back("save");
        return true;
      },
      [&](const std::string &, const std::string &) {
        calls.push_back("change");
        return true;
      },
      [&](const std::string &password) {
        calls.push_back("validate:" + password);
        return true;
      },
      [&] {
        calls.push_back("clear");
        return true;
      },
      [&] {
        calls.push_back("recover");
        return true;
      }};
  assert(sybl::archive::ReconcileArchiveProtection(kAccount, kSecret, true,
                                                   callbacks));
  assert(calls == std::vector<std::string>({"validate:" + kSecret}));
}

void WrongSealedSecretFailsOnEveryBoot() {
  for (int boot = 0; boot < 2; ++boot) {
    bool changed = false;
    const sybl::archive::ArchiveProtectionCallbacks callbacks{
        [](const std::string &, const std::string &) { return true; },
        [&](const std::string &, const std::string &) {
          changed = true;
          return true;
        },
        [](const std::string &) { return false; }, [] { return true; },
        [] { return true; }};
    assert(!sybl::archive::ReconcileArchiveProtection(kAccount, kSecret, true,
                                                      callbacks));
    assert(!changed);
  }
}

void MigrationJournalsBeforeChanging() {
  std::vector<std::string> calls;
  const sybl::archive::ArchiveProtectionCallbacks callbacks{
      [&](const std::string &desired, const std::string &transient) {
        assert(desired == kSecret);
        assert(transient.empty());
        calls.push_back("save");
        return true;
      },
      [&](const std::string &old_password, const std::string &new_password) {
        assert(old_password.empty());
        assert(new_password == kSecret);
        calls.push_back("change");
        return true;
      },
      [&](const std::string &password) {
        assert(password == kSecret);
        calls.push_back("validate");
        return true;
      },
      [&] {
        calls.push_back("clear");
        return true;
      },
      [&] {
        calls.push_back("recover");
        return true;
      }};
  assert(sybl::archive::ReconcileArchiveProtection(kAccount, kSecret, false,
                                                   callbacks));
  assert(calls ==
         std::vector<std::string>({"save", "change", "validate", "clear"}));
}

void UncertainChangeOrClearUsesRecovery() {
  for (const auto [change_result, clear_result] :
       {std::pair{false, true}, std::pair{true, false}}) {
    std::vector<std::string> calls;
    const sybl::archive::ArchiveProtectionCallbacks callbacks{
        [&](const std::string &, const std::string &) {
          calls.push_back("save");
          return true;
        },
        [&](const std::string &, const std::string &) {
          calls.push_back("change");
          return change_result;
        },
        [&](const std::string &) {
          calls.push_back("validate");
          return change_result;
        },
        [&] {
          calls.push_back("clear");
          return clear_result;
        },
        [&] {
          calls.push_back("recover");
          return true;
        }};
    assert(sybl::archive::ReconcileArchiveProtection(kAccount, kSecret, false,
                                                     callbacks));
    assert(calls.front() == "save");
    assert(calls.back() == "recover");
  }
}

void PersistenceFailureNeverChangesArchive() {
  bool changed = false;
  const sybl::archive::ArchiveProtectionCallbacks callbacks{
      [](const std::string &, const std::string &) { return false; },
      [&](const std::string &, const std::string &) {
        changed = true;
        return true;
      },
      [](const std::string &) { return true; }, [] { return true; },
      [] { return true; }};
  assert(!sybl::archive::ReconcileArchiveProtection(kAccount, kSecret, false,
                                                    callbacks));
  assert(!changed);
}

void SnapshotExportKeepsCredentialRolesSeparate() {
  std::vector<std::string> call;
  assert(sybl::archive::ExportArchiveSnapshot(
      kAccount, "backup.gz", kSecret, "user passphrase",
      [&](const std::string &account_id, const std::string &destination_path,
          const std::string &input_scheme, const std::string &input_password,
          const std::string &output_scheme,
          const std::string &output_password) {
        call = {account_id,     destination_path, input_scheme,
                input_password, output_scheme,    output_password};
        return true;
      }));
  assert(call ==
         std::vector<std::string>({kAccount, "backup.gz", "password", kSecret,
                                   "password", "user passphrase"}));
}

void SnapshotExportCanCreateUnprotectedDestination() {
  std::vector<std::string> call;
  assert(sybl::archive::ExportArchiveSnapshot(
      kAccount, "backup.gz", kSecret, "",
      [&](const std::string &account_id, const std::string &destination_path,
          const std::string &input_scheme, const std::string &input_password,
          const std::string &output_scheme,
          const std::string &output_password) {
        call = {account_id, destination_path, input_scheme, input_password,
                output_scheme, output_password};
        return true;
      }));
  assert(call ==
         std::vector<std::string>({kAccount, "backup.gz", "password", kSecret,
                                   "", ""}));
}

void InvalidSnapshotExportNeverCallsDaemon() {
  bool called = false;
  assert(!sybl::archive::ExportArchiveSnapshot(
      kAccount, "backup.gz", "wrong", "user passphrase",
      [&](const std::string &, const std::string &, const std::string &,
          const std::string &, const std::string &, const std::string &) {
        called = true;
        return true;
      }));
  assert(!called);
  assert(!sybl::archive::ExportArchiveSnapshot(
      kAccount, "backup.gz", kSecret, "user passphrase",
      [](const std::string &, const std::string &, const std::string &,
         const std::string &, const std::string &,
         const std::string &) { return false; }));
}

void SnapshotDetailsAreRestoredAfterEveryAttempt() {
  for (int failure = 0; failure < 4; ++failure) {
    std::vector<std::string> calls;
    const bool ok = sybl::archive::ExportWithRestoredAccountDetails(
        [&] {
          calls.push_back("temporary");
          if (failure == 1) throw std::runtime_error("uncertain write");
        },
        [&] {
          calls.push_back("export");
          if (failure == 2) throw std::runtime_error("export failure");
          return true;
        },
        [&] {
          calls.push_back("restore");
          if (failure == 3) throw std::runtime_error("restoration failure");
        });
    assert(ok == (failure == 0));
    assert(calls == (failure == 1
                        ? std::vector<std::string>{"temporary", "restore"}
                        : std::vector<std::string>{"temporary", "export", "restore"}));
  }
}

using sybl::archive::AccountReconcileOutcome;
using sybl::archive::ReconcileAccounts;

void AccountFailureIsStickyAcrossAccounts() {
  const AccountReconcileOutcome kinds[] = {
      AccountReconcileOutcome::kHealthy, AccountReconcileOutcome::kFailed,
      AccountReconcileOutcome::kIndeterminate};
  // Every ordering (with repetition) for two and three accounts.
  for (int count = 2; count <= 3; ++count) {
    int combinations = 1;
    for (int i = 0; i < count; ++i) combinations *= 3;
    for (int code = 0; code < combinations; ++code) {
      std::vector<std::string> accounts;
      std::vector<AccountReconcileOutcome> outcomes;
      bool all_healthy = true;
      int first_failure = -1;
      int rest = code;
      for (int i = 0; i < count; ++i) {
        const auto outcome = kinds[rest % 3];
        rest /= 3;
        accounts.push_back("a" + std::to_string(i));
        outcomes.push_back(outcome);
        if (outcome != AccountReconcileOutcome::kHealthy) all_healthy = false;
        if (outcome == AccountReconcileOutcome::kFailed && first_failure < 0)
          first_failure = i;
      }
      std::vector<std::string> visited;
      const bool ready = ReconcileAccounts(
          accounts, [&](const std::string &account) {
            visited.push_back(account);
            return outcomes[static_cast<size_t>(account[1] - '0')];
          });
      assert(ready == all_healthy);
      const size_t expected_visits =
          first_failure < 0 ? static_cast<size_t>(count)
                            : static_cast<size_t>(first_failure) + 1;
      assert(visited.size() == expected_visits);
      for (size_t i = 0; i < visited.size(); ++i)
        assert(visited[i] == accounts[i]);
    }
  }
}

void IndeterminateThenHealthyIsNotReady() {
  std::vector<std::string> visited;
  const bool ready = ReconcileAccounts(
      {"unreadable", "healthy"}, [&](const std::string &account) {
        visited.push_back(account);
        return account == "unreadable"
                   ? AccountReconcileOutcome::kIndeterminate
                   : AccountReconcileOutcome::kHealthy;
      });
  assert(!ready);
  assert((visited == std::vector<std::string>{"unreadable", "healthy"}));
}

void SkippedReservationsNeitherBlockNorHeal() {
  const auto run = [](const std::vector<AccountReconcileOutcome> &outcomes) {
    std::vector<std::string> accounts;
    for (size_t i = 0; i < outcomes.size(); ++i)
      accounts.push_back(std::to_string(i));
    return ReconcileAccounts(accounts, [&](const std::string &account) {
      return outcomes[static_cast<size_t>(std::stoi(account))];
    });
  };
  using O = AccountReconcileOutcome;
  assert(run({}));
  assert(run({O::kSkipped}));
  assert(run({O::kSkipped, O::kHealthy, O::kSkipped}));
  assert(!run({O::kIndeterminate, O::kSkipped}));
  assert(!run({O::kSkipped, O::kIndeterminate, O::kHealthy}));
  assert(!run({O::kFailed, O::kSkipped, O::kHealthy}));
}

} // namespace

int main() {
  AccountFailureIsStickyAcrossAccounts();
  IndeterminateThenHealthyIsNotReady();
  SkippedReservationsNeitherBlockNorHeal();
  SnapshotDetailsAreRestoredAfterEveryAttempt();
  ProtectedArchiveAlwaysProvesSecretWithoutRewrite();
  WrongSealedSecretFailsOnEveryBoot();
  MigrationJournalsBeforeChanging();
  UncertainChangeOrClearUsesRecovery();
  PersistenceFailureNeverChangesArchive();
  SnapshotExportKeepsCredentialRolesSeparate();
  SnapshotExportCanCreateUnprotectedDestination();
  InvalidSnapshotExportNeverCallsDaemon();
}
