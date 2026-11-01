#include "archive_secret_store.h"

#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <shlobj.h>
#include "uat_profile.h"

#include <algorithm>
#include <array>
#include <limits>
#include <vector>

#include "win32_dpapi.h"

namespace sybl::archive {
namespace {

constexpr std::size_t kRandomBytes = 32;
constexpr std::size_t kSecretCharacters = kRandomBytes * 2;
constexpr std::size_t kMaxSealedBytes = 64 * 1024;
constexpr char kHex[] = "0123456789abcdef";
constexpr char kPurpose[] = "archive-secret-v1";

struct ScopedHandle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~ScopedHandle() {
    if (value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
  ScopedHandle() = default;
};

enum class ReadStatus { kAbsent, kLoaded, kError };

struct ReadResult {
  ReadStatus status = ReadStatus::kError;
  std::string bytes;
};

ReadResult ReadBoundedFile(const std::filesystem::path& path) {
  ScopedHandle file;
  file.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                           nullptr);
  if (file.value == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    return {error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
                ? ReadStatus::kAbsent
                : ReadStatus::kError,
            {}};
  }
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file.value, &size) || size.QuadPart <= 0 ||
      size.QuadPart > static_cast<LONGLONG>(kMaxSealedBytes)) {
    return {ReadStatus::kError, {}};
  }
  std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  if (!ReadFile(file.value, bytes.data(), static_cast<DWORD>(bytes.size()),
                &read, nullptr) ||
      read != bytes.size()) {
    SecureZeroMemory(bytes.data(), bytes.size());
    return {ReadStatus::kError, {}};
  }
  return {ReadStatus::kLoaded, std::move(bytes)};
}

bool WriteDurably(const std::filesystem::path& path,
                  const std::string& bytes) {
  if (bytes.empty() || bytes.size() > kMaxSealedBytes) return false;
  const auto temporary = std::filesystem::path(path.wstring() + L".tmp");
  ScopedHandle file;
  file.value = CreateFileW(
      temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
  if (file.value == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool wrote =
      WriteFile(file.value, bytes.data(), static_cast<DWORD>(bytes.size()),
                &written, nullptr) &&
      written == bytes.size() && FlushFileBuffers(file.value);
  CloseHandle(file.value);
  file.value = INVALID_HANDLE_VALUE;
  if (!wrote ||
      !MoveFileExW(temporary.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

std::optional<std::string> GenerateSecret() {
  std::array<unsigned char, kRandomBytes> bytes{};
  if (!BCRYPT_SUCCESS(BCryptGenRandom(
          nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
          BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
    return std::nullopt;
  }
  std::string secret(kSecretCharacters, '\0');
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    secret[index * 2] = kHex[bytes[index] >> 4];
    secret[index * 2 + 1] = kHex[bytes[index] & 0x0f];
  }
  SecureZeroMemory(bytes.data(), bytes.size());
  return secret;
}

}  // namespace

ArchiveSecretStore::ArchiveSecretStore(std::filesystem::path path)
    : path_(std::move(path)) {}

std::optional<std::filesystem::path> ArchiveSecretStore::DefaultPath() {
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
  return directory / L"archive_secret.dpapi";
}

bool IsValidArchiveSecret(const std::string& value) {
  return value.size() == kSecretCharacters &&
         std::all_of(value.begin(), value.end(), [](unsigned char character) {
           return (character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f');
         });
}

std::optional<ArchiveSecretResult> ArchiveSecretStore::LoadOrCreate() {
  if (path_.empty()) return std::nullopt;
  std::error_code error;
  std::filesystem::create_directories(path_.parent_path(), error);
  if (error) return std::nullopt;

  // Serialize load/create across processes. The lock is released by Windows if
  // a process crashes, while a partial secret record remains visible and is
  // deliberately treated as corruption on the next attempt.
  const auto lock_path =
      std::filesystem::path(path_.wstring() + L".lock");
  ScopedHandle lock;
  lock.value = CreateFileW(lock_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                           nullptr, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_HIDDEN |
                               FILE_ATTRIBUTE_NOT_CONTENT_INDEXED,
                           nullptr);
  if (lock.value == INVALID_HANDLE_VALUE) return std::nullopt;

  sybl::win32::Win32DpapiProtector protector(kPurpose);
  auto existing = ReadBoundedFile(path_);
  if (existing.status == ReadStatus::kError) return std::nullopt;
  if (existing.status == ReadStatus::kLoaded) {
    auto clear = protector.Unprotect(existing.bytes);
    SecureZeroMemory(existing.bytes.data(), existing.bytes.size());
    if (!clear || !IsValidArchiveSecret(*clear)) {
      if (clear) SecureZeroMemory(clear->data(), clear->size());
      return std::nullopt;
    }
    ArchiveSecretResult result{*clear, false};
    SecureZeroMemory(clear->data(), clear->size());
    return result;
  }

  auto secret = GenerateSecret();
  if (!secret) return std::nullopt;
  auto sealed = protector.Protect(*secret);
  if (!sealed || !WriteDurably(path_, *sealed)) {
    SecureZeroMemory(secret->data(), secret->size());
    if (sealed) SecureZeroMemory(sealed->data(), sealed->size());
    return std::nullopt;
  }
  SecureZeroMemory(sealed->data(), sealed->size());

  // Read-after-write verifies both durable bytes and DPAPI decryptability
  // before libjami is allowed to adopt the password.
  auto persisted = ReadBoundedFile(path_);
  if (persisted.status != ReadStatus::kLoaded) {
    SecureZeroMemory(secret->data(), secret->size());
    return std::nullopt;
  }
  auto clear = protector.Unprotect(persisted.bytes);
  SecureZeroMemory(persisted.bytes.data(), persisted.bytes.size());
  const bool valid =
      clear && IsValidArchiveSecret(*clear) && *clear == *secret;
  if (clear) SecureZeroMemory(clear->data(), clear->size());
  if (!valid) {
    SecureZeroMemory(secret->data(), secret->size());
    return std::nullopt;
  }
  return ArchiveSecretResult{std::move(*secret), true};
}

}  // namespace sybl::archive
