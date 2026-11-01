#include "remote_control_grants.h"

#define NOMINMAX
#include <windows.h>
#include <shlobj.h>
#include "uat_profile.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>

namespace sybl::remote {
namespace {

constexpr char kMagic[] = "SYBLRCG1";
constexpr std::size_t kMaxRecords = 64;
constexpr std::size_t kMaxSealedBytes = 64 * 1024;

class Win32GrantTransaction final : public GrantBlobStorage::Transaction {
 public:
  explicit Win32GrantTransaction(HANDLE handle) : handle_(handle) {}
  ~Win32GrantTransaction() override {
    if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
  }

 private:
  HANDLE handle_ = INVALID_HANDLE_VALUE;
};

bool LowerHex(const std::string& value, std::size_t minimum,
              std::size_t maximum) {
  return value.size() >= minimum && value.size() <= maximum &&
      std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isdigit(c) || (c >= 'a' && c <= 'f');
      });
}

void Append32(std::string& output, std::uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8)
    output.push_back(static_cast<char>((value >> shift) & 0xff));
}

void Append64(std::string& output, std::uint64_t value) {
  for (int shift = 0; shift < 64; shift += 8)
    output.push_back(static_cast<char>((value >> shift) & 0xff));
}

void AppendString(std::string& output, const std::string& value) {
  Append32(output, static_cast<std::uint32_t>(value.size()));
  output.append(value);
}

bool Read32(const std::string& input, std::size_t& offset,
            std::uint32_t& value) {
  if (offset > input.size() || input.size() - offset < 4) return false;
  value = 0;
  for (int shift = 0; shift < 32; shift += 8)
    value |= static_cast<std::uint32_t>(
                 static_cast<unsigned char>(input[offset++]))
        << shift;
  return true;
}

bool Read64(const std::string& input, std::size_t& offset,
            std::uint64_t& value) {
  if (offset > input.size() || input.size() - offset < 8) return false;
  value = 0;
  for (int shift = 0; shift < 64; shift += 8)
    value |= static_cast<std::uint64_t>(
                 static_cast<unsigned char>(input[offset++]))
        << shift;
  return true;
}

bool ReadString(const std::string& input, std::size_t& offset,
                std::string& value, std::size_t maximum) {
  std::uint32_t length = 0;
  if (!Read32(input, offset, length) || length > maximum ||
      offset > input.size() || input.size() - offset < length) {
    return false;
  }
  value.assign(input.data() + offset, length);
  offset += length;
  return true;
}

}  // namespace

bool PersistentGrantKey::operator==(const PersistentGrantKey& other) const {
  return local_account == other.local_account &&
      controller_account == other.controller_account &&
      controller_device == other.controller_device;
}

PersistentGrantStore::PersistentGrantStore(GrantBlobStorage& storage,
                                           GrantBlobProtector& protector)
    : storage_(storage), protector_(protector) {}

bool PersistentGrantStore::ValidKey(const PersistentGrantKey& key) const {
  return LowerHex(key.local_account, 40, 40) &&
      LowerHex(key.controller_account, 40, 40) &&
      LowerHex(key.controller_device, 40, 128);
}

bool PersistentGrantStore::Expired(const Record& record,
                                   std::uint64_t now_ms) const {
  if (record.granted_ms == 0 || record.last_used_ms < record.granted_ms ||
      now_ms < record.granted_ms || now_ms < record.last_used_ms) {
    return true;
  }
  return now_ms - record.granted_ms >= kPersistentGrantTtlMs ||
      now_ms - record.last_used_ms >= kPersistentGrantTtlMs;
}

std::optional<std::vector<PersistentGrantStore::Record>>
PersistentGrantStore::LoadLocked() {
  auto sealed = storage_.Read();
  if (sealed.status == GrantBlobStorage::ReadStatus::kAbsent)
    return std::vector<Record>{};
  if (sealed.status != GrantBlobStorage::ReadStatus::kLoaded)
    return std::nullopt;
  if (sealed.bytes.empty() || sealed.bytes.size() > kMaxSealedBytes) {
    storage_.Remove();
    return std::nullopt;
  }
  const auto clear = protector_.Unprotect(sealed.bytes);
  if (!clear || clear->size() < sizeof(kMagic) - 1 + 4 ||
      std::memcmp(clear->data(), kMagic, sizeof(kMagic) - 1) != 0) {
    storage_.Remove();
    return std::nullopt;
  }
  std::size_t offset = sizeof(kMagic) - 1;
  std::uint32_t count = 0;
  if (!Read32(*clear, offset, count) || count > kMaxRecords) {
    storage_.Remove();
    return std::nullopt;
  }
  std::vector<Record> records;
  records.reserve(count);
  for (std::uint32_t index = 0; index < count; ++index) {
    Record record;
    if (!ReadString(*clear, offset, record.key.local_account, 40) ||
        !ReadString(*clear, offset, record.key.controller_account, 40) ||
        !ReadString(*clear, offset, record.key.controller_device, 128) ||
        !Read64(*clear, offset, record.granted_ms) ||
        !Read64(*clear, offset, record.last_used_ms) ||
        !ValidKey(record.key) || record.granted_ms == 0 ||
        record.last_used_ms < record.granted_ms) {
      storage_.Remove();
      return std::nullopt;
    }
    records.push_back(std::move(record));
  }
  if (offset != clear->size()) {
    storage_.Remove();
    return std::nullopt;
  }
  return records;
}

bool PersistentGrantStore::SaveLocked(const std::vector<Record>& records) {
  if (records.empty()) return storage_.Remove();
  if (records.size() > kMaxRecords) return false;
  std::string clear(kMagic, sizeof(kMagic) - 1);
  Append32(clear, static_cast<std::uint32_t>(records.size()));
  for (const auto& record : records) {
    AppendString(clear, record.key.local_account);
    AppendString(clear, record.key.controller_account);
    AppendString(clear, record.key.controller_device);
    Append64(clear, record.granted_ms);
    Append64(clear, record.last_used_ms);
  }
  const auto sealed = protector_.Protect(clear);
  return sealed && !sealed->empty() && sealed->size() <= kMaxSealedBytes &&
      storage_.Write(*sealed);
}

bool PersistentGrantStore::Save(const PersistentGrantKey& key,
                                std::uint64_t now_ms) {
  if (!ValidKey(key) || now_ms == 0) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (revocation_failed_.load()) return false;
  auto transaction = storage_.BeginTransaction();
  if (!transaction) return false;
  auto records = LoadLocked();
  if (!records) return false;
  records->erase(
      std::remove_if(records->begin(), records->end(),
                     [this, now_ms](const Record& record) {
                       return Expired(record, now_ms);
                     }),
      records->end());
  auto found = std::find_if(records->begin(), records->end(),
                            [&key](const Record& record) {
                              return record.key == key;
                            });
  if (found == records->end()) {
    if (records->size() >= kMaxRecords) records->erase(records->begin());
    records->push_back(Record{key, now_ms, now_ms});
  } else {
    found->granted_ms = now_ms;
    found->last_used_ms = now_ms;
  }
  return SaveLocked(*records);
}

bool PersistentGrantStore::Matches(const PersistentGrantKey& key,
                                   std::uint64_t now_ms) {
  if (!ValidKey(key) || now_ms == 0) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (revocation_failed_.load()) return false;
  auto transaction = storage_.BeginTransaction();
  if (!transaction) return false;
  auto records = LoadLocked();
  if (!records) return false;
  bool changed = false;
  records->erase(
      std::remove_if(records->begin(), records->end(),
                     [this, now_ms, &changed](const Record& record) {
                       const bool expired = Expired(record, now_ms);
                       changed = changed || expired;
                       return expired;
                     }),
      records->end());
  auto found = std::find_if(records->begin(), records->end(),
                            [&key](const Record& record) {
                              return record.key == key;
                            });
  if (found == records->end()) {
    if (changed) SaveLocked(*records);
    return false;
  }
  if (changed && !SaveLocked(*records)) return false;
  return true;
}

bool PersistentGrantStore::Touch(const PersistentGrantKey& key,
                                 std::uint64_t now_ms) {
  if (!ValidKey(key) || now_ms == 0) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (revocation_failed_.load()) return false;
  auto transaction = storage_.BeginTransaction();
  if (!transaction) return false;
  auto records = LoadLocked();
  if (!records) return false;
  auto found = std::find_if(records->begin(), records->end(),
                            [&key](const Record& record) {
                              return record.key == key;
                            });
  if (found == records->end() || Expired(*found, now_ms)) return false;
  found->last_used_ms = now_ms;
  return SaveLocked(*records);
}

bool PersistentGrantStore::Remove(const PersistentGrantKey& key) {
  if (!ValidKey(key)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  try {
    auto transaction = storage_.BeginTransaction();
    if (!transaction) {
      revocation_failed_ = true;
      return false;
    }
    auto records = LoadLocked();
    if (!records) {
      revocation_failed_ = true;
      return false;
    }
    const auto size = records->size();
    records->erase(
        std::remove_if(records->begin(), records->end(),
                       [&key](const Record& record) {
                         return record.key == key;
                       }),
        records->end());
    bool removed = records->size() == size || SaveLocked(*records);
    const auto verified = removed ? LoadLocked() : std::nullopt;
    removed = verified && std::none_of(verified->begin(), verified->end(),
        [&key](const Record& record) { return record.key == key; });
    if (!removed) revocation_failed_ = true;
    return removed;
  } catch (...) {
    revocation_failed_ = true;
    return false;
  }
}

bool PersistentGrantStore::RemovePeer(const std::string& local_account,
                                      const std::string& controller_account) {
  if (!LowerHex(local_account, 40, 40) ||
      !LowerHex(controller_account, 40, 40)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  try {
    auto transaction = storage_.BeginTransaction();
    auto records = transaction ? LoadLocked() : std::nullopt;
    if (!records) {
      revocation_failed_ = true;
      return false;
    }
    const auto size = records->size();
    records->erase(std::remove_if(records->begin(), records->end(),
        [&](const Record& record) {
          return record.key.local_account == local_account &&
              record.key.controller_account == controller_account;
        }), records->end());
    bool removed = records->size() == size || SaveLocked(*records);
    const auto verified = removed ? LoadLocked() : std::nullopt;
    removed = verified && std::none_of(verified->begin(), verified->end(),
        [&](const Record& record) {
          return record.key.local_account == local_account &&
              record.key.controller_account == controller_account;
        });
    if (!removed) revocation_failed_ = true;
    return removed;
  } catch (...) {
    revocation_failed_ = true;
    return false;
  }
}

std::optional<std::wstring> Win32GrantBlobStorage::Path() const {
  PWSTR local = nullptr;
  if (FAILED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &local)) ||
      !local) {
    return std::nullopt;
  }
  std::filesystem::path directory(local);
  CoTaskMemFree(local);
  directory /= L"Syb-L";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return std::nullopt;
  return (directory / L"remote_control_grants.dpapi").wstring();
}

std::unique_ptr<GrantBlobStorage::Transaction>
Win32GrantBlobStorage::BeginTransaction() {
  const auto path = Path();
  if (!path) return nullptr;
  const std::wstring lock_path = *path + L".lock";
  const HANDLE handle = CreateFileW(
      lock_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED,
      nullptr);
  if (handle == INVALID_HANDLE_VALUE) return nullptr;
  return std::make_unique<Win32GrantTransaction>(handle);
}

GrantBlobStorage::ReadResult Win32GrantBlobStorage::Read() {
  const auto path = Path();
  if (!path) return {};
  const HANDLE file =
      CreateFileW(path->c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    return {
        error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
            ? ReadStatus::kAbsent
            : ReadStatus::kError,
        {}};
  }
  LARGE_INTEGER length{};
  if (!GetFileSizeEx(file, &length) || length.QuadPart <= 0 ||
      length.QuadPart > static_cast<LONGLONG>(kMaxSealedBytes)) {
    CloseHandle(file);
    return {};
  }
  std::string bytes(static_cast<std::size_t>(length.QuadPart), '\0');
  DWORD read = 0;
  const bool ok =
      ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read,
               nullptr) &&
      read == bytes.size();
  CloseHandle(file);
  return ok ? ReadResult{ReadStatus::kLoaded, std::move(bytes)}
            : ReadResult{};
}

bool Win32GrantBlobStorage::Write(const std::string& bytes) {
  const auto path = Path();
  if (!path || bytes.empty() || bytes.size() > kMaxSealedBytes) return false;
  const std::wstring temporary = *path + L".tmp";
  const HANDLE file = CreateFileW(
      temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool wrote =
      WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
                nullptr) &&
      written == bytes.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!wrote) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  if (!MoveFileExW(temporary.c_str(), path->c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  const auto persisted = Read();
  return persisted.status == ReadStatus::kLoaded &&
      persisted.bytes == bytes;
}

bool Win32GrantBlobStorage::Remove() {
  const auto path = Path();
  if (!path) return false;
  DeleteFileW((*path + L".tmp").c_str());
  if (DeleteFileW(path->c_str())) return true;
  const DWORD error = GetLastError();
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

std::optional<std::string> Win32GrantDpapiProtector::Protect(
    const std::string& clear) {
  return protector_.Protect(clear);
}

std::optional<std::string> Win32GrantDpapiProtector::Unprotect(
    const std::string& sealed) {
  return protector_.Unprotect(sealed);
}

}  // namespace sybl::remote
