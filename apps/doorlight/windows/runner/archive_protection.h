#pragma once

#include <functional>
#include <string>
#include <vector>

namespace sybl::archive {

struct ArchiveProtectionCallbacks {
  std::function<bool(const std::string &desired_secret,
                     const std::string &transient_secret)>
      save_recovery;
  std::function<bool(const std::string &old_password,
                     const std::string &new_password)>
      change_password;
  std::function<bool(const std::string &password)> validate_password;
  std::function<bool()> clear_recovery;
  std::function<bool()> recover;
};

// Transactionally reconciles one libjami archive with the device-bound
// password. Present protected archives are proven read-only on every boot.
bool ReconcileArchiveProtection(const std::string &account_id,
                                const std::string &device_secret,
                                bool archive_has_password,
                                const ArchiveProtectionCallbacks &callbacks);

enum class AccountReconcileOutcome {
  kHealthy,
  kFailed,        // reconciliation itself failed: stop processing
  kIndeterminate, // protection state unreadable: keep going, never ready
  kSkipped,       // unacknowledged pairing reservation: not this pass's account
};

// Visits accounts in order and is ready only if every non-skipped account is
// healthy. A failed or indeterminate outcome is sticky: a later healthy account
// never replaces it. Processing stops at the first failure and continues past
// an indeterminate account.
bool ReconcileAccounts(
    const std::vector<std::string> &accounts,
    const std::function<AccountReconcileOutcome(const std::string &)>
        &reconcile_one);

using SnapshotExporter = std::function<bool(
    const std::string &account_id, const std::string &destination_path,
    const std::string &input_scheme, const std::string &input_password,
    const std::string &output_scheme, const std::string &output_password)>;

// Writes a separately encrypted snapshot without changing the live archive.
// Input and output credential roles are deliberately not inferred or swapped.
bool ExportArchiveSnapshot(const std::string &account_id,
                           const std::string &destination_path,
                           const std::string &device_secret,
                           const std::string &backup_passphrase,
                           const SnapshotExporter &exporter);

// Restores live details after a temporary backup customization, including an
// uncertain write that throws after taking effect.
bool ExportWithRestoredAccountDetails(const std::function<void()>& apply,
                                     const std::function<bool()>& export_snapshot,
                                     const std::function<void()>& restore);

} // namespace sybl::archive
