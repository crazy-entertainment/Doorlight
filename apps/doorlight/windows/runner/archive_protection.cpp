#include "archive_protection.h"

#include "archive_secret_store.h"

namespace sybl::archive {

bool ReconcileAccounts(
    const std::vector<std::string> &accounts,
    const std::function<AccountReconcileOutcome(const std::string &)>
        &reconcile_one) {
  bool ready = true;
  for (const auto &account : accounts) {
    switch (reconcile_one(account)) {
    case AccountReconcileOutcome::kHealthy:
    case AccountReconcileOutcome::kSkipped:
      break;
    case AccountReconcileOutcome::kIndeterminate:
      ready = false;
      break;
    case AccountReconcileOutcome::kFailed:
    default:
      return false;
    }
  }
  return ready;
}

bool ReconcileArchiveProtection(const std::string &account_id,
                                const std::string &device_secret,
                                bool archive_has_password,
                                const ArchiveProtectionCallbacks &callbacks) {
  if (account_id.empty() || !IsValidArchiveSecret(device_secret) ||
      !callbacks.save_recovery || !callbacks.change_password ||
      !callbacks.validate_password || !callbacks.clear_recovery ||
      !callbacks.recover) {
    return false;
  }

  if (archive_has_password) {
    // Never infer authority from the sealed-store lifecycle. A validly
    // formatted but wrong secret can survive every later boot, so prove it
    // against libjami without rewriting the archive.
    return callbacks.validate_password(device_secret);
  }

  // The journal's desired state is the device secret; the empty transient
  // value is the plaintext state from which recovery should continue.
  if (!callbacks.save_recovery(device_secret, std::string()))
    return false;
  callbacks.change_password(std::string(), device_secret);
  if (callbacks.validate_password(device_secret) &&
      callbacks.clear_recovery()) {
    return true;
  }

  // The change can report false after committing, and a failed verification
  // or journal clear leaves state uncertain. Only durable recovery may decide
  // whether migration still needs doing or already committed.
  return callbacks.recover();
}

bool ExportArchiveSnapshot(const std::string &account_id,
                           const std::string &destination_path,
                           const std::string &device_secret,
                           const std::string &backup_passphrase,
                           const SnapshotExporter &exporter) {
  if (account_id.empty() || destination_path.empty() ||
      !IsValidArchiveSecret(device_secret) || !exporter) {
    return false;
  }
  const auto output_scheme =
      backup_passphrase.empty() ? std::string{} : std::string{"password"};
  return exporter(account_id, destination_path, "password", device_secret,
                  output_scheme, backup_passphrase);
}

bool ExportWithRestoredAccountDetails(const std::function<void()>& apply,
                                     const std::function<bool()>& export_snapshot,
                                     const std::function<void()>& restore) {
  if (!apply || !export_snapshot || !restore) return false;
  bool ok = false;
  try {
    apply();
    ok = export_snapshot();
  } catch (...) { ok = false; }
  // A throwing settings write may already have mutated live customization.
  try { restore(); } catch (...) { ok = false; }
  return ok;
}

} // namespace sybl::archive
