#pragma once

#include "win32_dpapi.h"

#include <cstdint>
#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace sybl::remote {

constexpr std::uint64_t kPersistentGrantTtlMs =
    30ULL * 24ULL * 60ULL * 60ULL * 1000ULL;

struct PersistentGrantKey {
  std::string local_account;
  std::string controller_account;
  std::string controller_device;

  bool operator==(const PersistentGrantKey& other) const;
};

class GrantBlobStorage {
 public:
  enum class ReadStatus {
    kAbsent,
    kLoaded,
    kError,
  };

  struct ReadResult {
    ReadStatus status = ReadStatus::kError;
    std::string bytes;
  };

  // Keeps one read/modify/write transaction indivisible across application
  // processes. Test stores may use the no-op base token.
  class Transaction {
   public:
    virtual ~Transaction() = default;
  };

  virtual ~GrantBlobStorage() = default;
  virtual std::unique_ptr<Transaction> BeginTransaction() {
    return std::make_unique<Transaction>();
  }
  virtual ReadResult Read() = 0;
  virtual bool Write(const std::string& bytes) = 0;
  virtual bool Remove() = 0;
};

class GrantBlobProtector {
 public:
  virtual ~GrantBlobProtector() = default;
  virtual std::optional<std::string> Protect(const std::string& clear) = 0;
  virtual std::optional<std::string> Unprotect(const std::string& sealed) = 0;
};

class PersistentGrantStore {
 public:
  PersistentGrantStore(GrantBlobStorage& storage,
                       GrantBlobProtector& protector);

  bool Save(const PersistentGrantKey& key, std::uint64_t now_ms);
  bool Matches(const PersistentGrantKey& key, std::uint64_t now_ms);
  bool Touch(const PersistentGrantKey& key, std::uint64_t now_ms);
  bool Remove(const PersistentGrantKey& key);
  bool RemovePeer(const std::string& local_account,
                  const std::string& controller_account);

  // Whether Save could ever accept this key. The UI must not offer "skip the
  // prompt next time" for a key the store will reject at Save time — that
  // would ship a control that silently does nothing.
  bool CanStore(const PersistentGrantKey& key) const {
    return !revocation_failed_.load() && ValidKey(key);
  }

 private:
  struct Record {
    PersistentGrantKey key;
    std::uint64_t granted_ms = 0;
    std::uint64_t last_used_ms = 0;
  };

  bool ValidKey(const PersistentGrantKey& key) const;
  bool Expired(const Record& record, std::uint64_t now_ms) const;
  std::optional<std::vector<Record>> LoadLocked();
  bool SaveLocked(const std::vector<Record>& records);

  GrantBlobStorage& storage_;
  GrantBlobProtector& protector_;
  std::mutex mutex_;
  // A failed security-sensitive deletion cannot leave saved authority usable
  // in this process. The caller reports failure; this is not durable deletion.
  std::atomic<bool> revocation_failed_{false};
};

class Win32GrantBlobStorage final : public GrantBlobStorage {
 public:
  std::unique_ptr<Transaction> BeginTransaction() override;
  ReadResult Read() override;
  bool Write(const std::string& bytes) override;
  bool Remove() override;

 private:
  std::optional<std::wstring> Path() const;
};

class Win32GrantDpapiProtector final : public GrantBlobProtector {
 public:
  std::optional<std::string> Protect(const std::string& clear) override;
  std::optional<std::string> Unprotect(const std::string& sealed) override;

 private:
  sybl::win32::Win32DpapiProtector protector_{
      "remote-control grants v1"};
};

}  // namespace sybl::remote
