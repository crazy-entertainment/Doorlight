#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace sybl::identity_restore {

inline constexpr size_t kMaxSettingsBytes = 64 * 1024;

// Export uses the native account owner, not a caller-supplied metadata owner.
std::optional<std::string> StampBackupSettings(
    const std::string& document, const std::string& account_id);
std::string BackupSourceAccount(const std::string& document);

enum class Phase { kImporting, kPrepared, kPrivacyCommitted, kRollingBack };

// Persisted disable alone does not retire volatile activity after partial activation.
inline bool PreparedIdentityClosed(const std::string& enabled, const std::string& active) {
  return enabled == "false" && active == "false";
}

struct PendingRestore {
  std::string token;
  std::string account_id;
  std::string previous_account_id;
  Phase phase = Phase::kImporting;
  bool appear_offline = false;
  std::string settings_document;
  std::string normalized_document;
  std::map<std::string, std::string> network_details;
  bool settings_already_normalized = false;
  // Present only for a device-link transaction. No URI, code, or source secret
  // is persisted here. Acknowledgement is required before ordinary activation.
  std::optional<uint32_t> pairing_operation;
  bool pairing_acknowledged = false;
  // Archive restores carry the independently known, canonical Friend ID.
  // Empty only for device pairing or a legacy restore awaiting discard.
  std::string expected_jami_id;
};

std::optional<std::string> EncodePending(const PendingRestore& value);
std::optional<PendingRestore> DecodePending(const std::string& bytes);
bool CanAdoptAccount(const std::string& account_id,
                     const std::optional<PendingRestore>& pending, bool unreadable_marker);
bool CanDiscard(const PendingRestore& pending, const std::string& selected_account,
                const std::vector<std::string>& accounts);
bool IsNormalizedSettings(const std::string& document);
std::optional<std::string> RandomToken();

enum class LoadStatus { kAbsent, kLoaded, kError };
struct LoadResult {
  LoadStatus status = LoadStatus::kError;
  std::optional<PendingRestore> value;
};

// A separate DPAPI record. Rekey recovery must not clear this privacy gate.
class PendingRestoreStore {
 public:
  explicit PendingRestoreStore(std::filesystem::path path);
  static std::optional<std::filesystem::path> DefaultPath();
  LoadResult Load() const;
  bool Save(const PendingRestore& value, bool disabled_reprepare = false) const;
  bool Clear(const std::string& expected_token) const;
 private:
  std::filesystem::path path_;
};

// Holds the existing canonical file against concurrent writers until the
// enable/select operation ends. It never changes preference bytes.
class CanonicalSettingsLease {
 public:
  ~CanonicalSettingsLease();
  CanonicalSettingsLease(const CanonicalSettingsLease&) = delete;
  CanonicalSettingsLease& operator=(const CanonicalSettingsLease&) = delete;
  static std::unique_ptr<CanonicalSettingsLease> Acquire(
      const std::filesystem::path& path, const std::string& document);
  static std::unique_ptr<CanonicalSettingsLease> AcquireCurrent(
      const std::filesystem::path& path, bool require_durable = true);
  bool appear_offline() const { return appear_offline_; }
  bool AllowsFriendHolograms(const std::string& account, const std::string& peer) const;
  static std::optional<std::filesystem::path> DefaultPath();
 private:
  explicit CanonicalSettingsLease(void* handle);
  void* handle_;
  std::string document_;
  bool appear_offline_ = false;
};

struct FinalizeCallbacks {
  std::function<bool()> owns_operation;
  std::function<bool(const std::string&)> lock_and_flush_settings;
  std::function<bool(const PendingRestore&)> save_pending;
  std::function<bool(bool)> enable_and_select;
  std::function<bool()> clear_pending;
};

// The production activation order is also exercised with synthetic callbacks.
bool Finalize(PendingRestore& pending, const std::string& account_id,
              const std::string& token, const std::string& document,
              const FinalizeCallbacks& callbacks);

struct RollbackCallbacks {
  std::function<bool()> owns_operation;
  std::function<bool(const PendingRestore&)> save_pending;
  std::function<bool()> remove_and_confirm_absent;
  std::function<bool()> clear_journals;
};

bool Rollback(PendingRestore& pending, const std::string& selected_account,
              const std::vector<std::string>& accounts,
              const RollbackCallbacks& callbacks);

}  // namespace sybl::identity_restore
