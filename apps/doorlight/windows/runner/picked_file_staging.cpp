#include "picked_file_staging.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <bcrypt.h>
#include <shlobj.h>
#include "uat_profile.h"

#include <algorithm>
#include <array>
#include <cwctype>
#include <iterator>
#include <string>
#include <system_error>
#include <vector>

namespace sybl::picked_file {
namespace {

constexpr wchar_t kDirectoryPrefix[] = L"picked-";

class UniqueHandle {
 public:
  UniqueHandle() = default;
  explicit UniqueHandle(HANDLE value) : value_(value) {}
  ~UniqueHandle() { Reset(); }

  UniqueHandle(const UniqueHandle&) = delete;
  UniqueHandle& operator=(const UniqueHandle&) = delete;

  HANDLE Get() const { return value_; }
  explicit operator bool() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }
  HANDLE Release() {
    const HANDLE value = value_;
    value_ = INVALID_HANDLE_VALUE;
    return value;
  }
  void Reset(HANDLE value = INVALID_HANDLE_VALUE) {
    if (*this) CloseHandle(value_);
    value_ = value;
  }

 private:
  HANDLE value_ = INVALID_HANDLE_VALUE;
};

bool MarkForDeletion(HANDLE file) {
  FILE_DISPOSITION_INFO disposition{};
  disposition.DeleteFile = TRUE;
  return SetFileInformationByHandle(file, FileDispositionInfo, &disposition,
                                    sizeof(disposition)) != FALSE;
}

class PartialOutput {
 public:
  explicit PartialOutput(HANDLE file) : file_(file) {}
  ~PartialOutput() {
    if (file_) MarkForDeletion(file_.Get());
  }

  HANDLE Get() const { return file_.Get(); }

  bool Commit() {
    if (!file_ || !FlushFileBuffers(file_.Get())) return false;
    file_.Reset();
    return true;
  }

 private:
  UniqueHandle file_;
};

class PartialDirectory {
 public:
  explicit PartialDirectory(HANDLE directory) : directory_(directory) {}
  ~PartialDirectory() {
    if (directory_) MarkForDeletion(directory_.Get());
  }

  void Commit() { directory_.Reset(); }

 private:
  UniqueHandle directory_;
};

std::optional<std::wstring> FullPath(const std::filesystem::path& path) {
  if (path.empty() || !path.is_absolute()) return std::nullopt;
  const DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (required == 0) return std::nullopt;
  std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
  const DWORD written = GetFullPathNameW(
      path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
  if (written == 0 || written >= static_cast<DWORD>(buffer.size()))
    return std::nullopt;
  // Expand 8.3 aliases without resolving reparse points. Handle validation
  // below still requires the final path to match this selected path.
  const DWORD long_required = GetLongPathNameW(buffer.data(), nullptr, 0);
  if (long_required == 0) return std::nullopt;
  std::vector<wchar_t> long_buffer(static_cast<std::size_t>(long_required) + 1);
  const DWORD long_written = GetLongPathNameW(
      buffer.data(), long_buffer.data(), static_cast<DWORD>(long_buffer.size()));
  if (long_written == 0 || long_written >= static_cast<DWORD>(long_buffer.size()))
    return std::nullopt;
  return std::wstring(long_buffer.data(), long_written);
}

std::optional<std::wstring> FinalPath(HANDLE file) {
  const DWORD required = GetFinalPathNameByHandleW(
      file, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (required == 0) return std::nullopt;
  std::vector<wchar_t> buffer(static_cast<std::size_t>(required) + 1);
  const DWORD written = GetFinalPathNameByHandleW(
      file, buffer.data(), static_cast<DWORD>(buffer.size()),
      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= static_cast<DWORD>(buffer.size()))
    return std::nullopt;
  return std::wstring(buffer.data(), written);
}

std::wstring ComparablePath(std::wstring value) {
  constexpr wchar_t kUncPrefix[] = L"\\\\?\\UNC\\";
  constexpr wchar_t kPathPrefix[] = L"\\\\?\\";
  if (value.compare(0, std::size(kUncPrefix) - 1, kUncPrefix) == 0) {
    value = L"\\\\" + value.substr(std::size(kUncPrefix) - 1);
  } else if (value.compare(0, std::size(kPathPrefix) - 1, kPathPrefix) == 0) {
    value.erase(0, std::size(kPathPrefix) - 1);
  }
  std::replace(value.begin(), value.end(), L'/', L'\\');
  while (value.size() > 3 && value.back() == L'\\') value.pop_back();
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  return value;
}

bool SamePath(const std::wstring& left, const std::wstring& right) {
  return ComparablePath(left) == ComparablePath(right);
}

bool OpenValidatedDirectory(const std::filesystem::path& root,
                            UniqueHandle& directory,
                            std::wstring& full_path,
                            DWORD access = FILE_READ_ATTRIBUTES) {
  const auto full = FullPath(root);
  if (!full) return false;
  directory.Reset(CreateFileW(
      full->c_str(), access,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory || GetFileType(directory.Get()) != FILE_TYPE_DISK) return false;
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (!GetFileInformationByHandleEx(directory.Get(), FileAttributeTagInfo,
                                    &attributes, sizeof(attributes)) ||
      (attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  const auto final = FinalPath(directory.Get());
  if (!final || !SamePath(*full, *final)) return false;
  full_path = *full;
  return true;
}

bool RegularFileInfo(HANDLE file, const std::wstring& expected_path,
                     std::uint64_t& size) {
  if (GetFileType(file) != FILE_TYPE_DISK) return false;
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &attributes,
                                    sizeof(attributes)) ||
      (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY |
                                    FILE_ATTRIBUTE_REPARSE_POINT |
                                    FILE_ATTRIBUTE_DEVICE)) != 0) {
    return false;
  }
  FILE_STANDARD_INFO standard{};
  if (!GetFileInformationByHandleEx(file, FileStandardInfo, &standard,
                                    sizeof(standard)) ||
      standard.Directory || standard.EndOfFile.QuadPart < 0) {
    return false;
  }
  const auto final = FinalPath(file);
  if (!final || !SamePath(expected_path, *final)) return false;
  size = static_cast<std::uint64_t>(standard.EndOfFile.QuadPart);
  return true;
}

std::optional<std::wstring> NewStagedDirectoryName() {
  std::array<unsigned char, 16> random{};
  if (BCryptGenRandom(nullptr, random.data(),
                      static_cast<ULONG>(random.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    return std::nullopt;
  }
  constexpr wchar_t kHex[] = L"0123456789abcdef";
  std::wstring name(kDirectoryPrefix);
  name.reserve((std::size(kDirectoryPrefix) - 1) + random.size() * 2);
  for (const auto byte : random) {
    name.push_back(kHex[byte >> 4]);
    name.push_back(kHex[byte & 0x0f]);
  }
  return name;
}

bool IsStagedDirectoryName(const std::filesystem::path& path) {
  const auto name = path.filename().wstring();
  const std::size_t prefix = std::size(kDirectoryPrefix) - 1;
  if (name.size() != prefix + 32 ||
      name.compare(0, prefix, kDirectoryPrefix) != 0) {
    return false;
  }
  return std::all_of(name.begin() + static_cast<std::ptrdiff_t>(prefix),
                     name.end(),
                     [](wchar_t character) {
                       return (character >= L'0' && character <= L'9') ||
                              (character >= L'a' && character <= L'f');
                     });
}

}  // namespace

std::optional<std::filesystem::path> DefaultStagingRoot() {
  PWSTR local = nullptr;
  if (FAILED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &local)) ||
      local == nullptr) {
    return std::nullopt;
  }
  std::filesystem::path root(local);
  CoTaskMemFree(local);
  return root / L"Syb-L Picker Staging";
}

std::optional<std::filesystem::path> ReserveRecordingOutput(
    const std::filesystem::path& staging_root) {
  return ReserveReceivedMediaOutput(staging_root, false);
}

std::optional<std::filesystem::path> ReserveReceivedMediaOutput(
    const std::filesystem::path& staging_root, bool gif, bool create_placeholder) {
  if (!staging_root.is_absolute()) return std::nullopt;
  std::error_code error;
  std::filesystem::create_directories(staging_root, error);
  if (error) return std::nullopt;
  UniqueHandle root;
  std::wstring root_path;
  if (!OpenValidatedDirectory(staging_root, root, root_path))
    return std::nullopt;
  for (int attempt = 0; attempt < 32; ++attempt) {
    const auto name = NewStagedDirectoryName();
    if (!name) return std::nullopt;
    const auto directory_path = std::filesystem::path(root_path) / *name;
    if (!CreateDirectoryW(directory_path.c_str(), nullptr)) {
      if (GetLastError() == ERROR_ALREADY_EXISTS) continue;
      return std::nullopt;
    }
    UniqueHandle directory;
    std::wstring full_directory;
    if (!OpenValidatedDirectory(directory_path, directory, full_directory,
                                DELETE | FILE_READ_ATTRIBUTES)) {
      RemoveDirectoryW(directory_path.c_str());
      return std::nullopt;
    }
    PartialDirectory pending_directory(directory.Release());
    const auto destination = std::filesystem::path(full_directory) /
        (gif ? L"media.gif" : L"voice.m4a");
    if (!create_placeholder) {
      pending_directory.Commit();
      return destination;
    }
    HANDLE handle = CreateFileW(destination.c_str(),
        GENERIC_WRITE | FILE_READ_ATTRIBUTES | DELETE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return std::nullopt;
    PartialOutput output(handle);
    std::uint64_t size = 0;
    if (!RegularFileInfo(output.Get(), destination.wstring(), size) ||
        size != 0 || !output.Commit()) return std::nullopt;
    pending_directory.Commit();
    return destination;
  }
  return std::nullopt;
}

std::optional<std::filesystem::path> Stage(
    const std::filesystem::path& selected,
    const std::filesystem::path& staging_root, std::int64_t max_bytes) {
  if (!IsAllowedMaxBytes(max_bytes) || selected.empty() ||
      !selected.is_absolute() || !staging_root.is_absolute() ||
      selected.filename().wstring().find(L':') != std::wstring::npos) {
    return std::nullopt;
  }
  const auto source_path = FullPath(selected);
  if (!source_path) return std::nullopt;
  UniqueHandle source(CreateFileW(
      source_path->c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
  std::uint64_t source_size = 0;
  if (!source ||
      !RegularFileInfo(source.Get(), *source_path, source_size) ||
      source_size > static_cast<std::uint64_t>(max_bytes)) {
    return std::nullopt;
  }

  std::error_code error;
  std::filesystem::create_directories(staging_root, error);
  if (error) return std::nullopt;
  UniqueHandle directory;
  std::wstring root_path;
  if (!OpenValidatedDirectory(staging_root, directory, root_path))
    return std::nullopt;

  for (int attempt = 0; attempt < 32; ++attempt) {
    const auto directory_name = NewStagedDirectoryName();
    if (!directory_name) return std::nullopt;
    const std::filesystem::path staged_directory_path =
        std::filesystem::path(root_path) / *directory_name;
    if (!CreateDirectoryW(staged_directory_path.c_str(), nullptr)) {
      if (GetLastError() == ERROR_ALREADY_EXISTS) continue;
      return std::nullopt;
    }
    UniqueHandle staged_directory_handle;
    std::wstring staged_directory_full_path;
    if (!OpenValidatedDirectory(
            staged_directory_path, staged_directory_handle,
            staged_directory_full_path, DELETE | FILE_READ_ATTRIBUTES)) {
      RemoveDirectoryW(staged_directory_path.c_str());
      return std::nullopt;
    }
    PartialDirectory staged_directory(staged_directory_handle.Release());
    const std::filesystem::path destination =
        std::filesystem::path(staged_directory_full_path) /
        selected.filename();
    HANDLE raw_output = CreateFileW(
        destination.c_str(), GENERIC_WRITE | FILE_READ_ATTRIBUTES | DELETE, 0,
        nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (raw_output == INVALID_HANDLE_VALUE) return std::nullopt;
    PartialOutput output(raw_output);
    std::uint64_t output_size = 0;
    const auto destination_path = FullPath(destination);
    if (!destination_path ||
        !RegularFileInfo(output.Get(), *destination_path, output_size) ||
        output_size != 0) {
      return std::nullopt;
    }

    std::array<unsigned char, 64 * 1024> buffer{};
    std::uint64_t total = 0;
    for (;;) {
      DWORD read = 0;
      if (!ReadFile(source.Get(), buffer.data(),
                    static_cast<DWORD>(buffer.size()), &read, nullptr)) {
        return std::nullopt;
      }
      if (read == 0) break;
      if (static_cast<std::uint64_t>(read) >
          static_cast<std::uint64_t>(max_bytes) - total) {
        return std::nullopt;
      }
      DWORD offset = 0;
      while (offset < read) {
        DWORD written = 0;
        if (!WriteFile(output.Get(), buffer.data() + offset, read - offset,
                       &written, nullptr) ||
            written == 0) {
          return std::nullopt;
        }
        offset += written;
      }
      total += read;
    }
    if (total != source_size) return std::nullopt;
    FILE_STANDARD_INFO copied{};
    if (!GetFileInformationByHandleEx(output.Get(), FileStandardInfo, &copied,
                                      sizeof(copied)) ||
        copied.EndOfFile.QuadPart < 0 ||
        static_cast<std::uint64_t>(copied.EndOfFile.QuadPart) != total ||
        !output.Commit()) {
      return std::nullopt;
    }
    staged_directory.Commit();
    return destination;
  }
  return std::nullopt;
}

static bool ValidateStaged(const std::filesystem::path& candidate,
                           const std::filesystem::path& staging_root,
                           bool remove) {
  if (candidate.empty() || !candidate.is_absolute() ||
      candidate.filename().empty() ||
      candidate.filename().wstring().find(L':') != std::wstring::npos) {
    return false;
  }
  UniqueHandle directory;
  std::wstring root_path;
  if (!OpenValidatedDirectory(staging_root, directory, root_path)) return false;
  const auto candidate_path = FullPath(candidate);
  if (!candidate_path) return false;
  const auto staged_directory_path =
      std::filesystem::path(*candidate_path).parent_path();
  if (!IsStagedDirectoryName(staged_directory_path) ||
      !SamePath(staged_directory_path.parent_path().wstring(), root_path)) {
    return false;
  }
  UniqueHandle staged_directory;
  std::wstring staged_directory_full_path;
  if (!OpenValidatedDirectory(
          staged_directory_path, staged_directory,
          staged_directory_full_path, (remove ? DELETE : 0) | FILE_READ_ATTRIBUTES) ||
      !SamePath(staged_directory_full_path,
                std::filesystem::path(*candidate_path).parent_path().wstring())) {
    return false;
  }
  UniqueHandle file(CreateFileW(
      candidate_path->c_str(), (remove ? DELETE : 0) | FILE_READ_ATTRIBUTES, 0, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  std::uint64_t ignored_size = 0;
  if (!file ||
      !RegularFileInfo(file.Get(), *candidate_path, ignored_size)) {
    return false;
  }
  if (!remove) return true;
  if (!MarkForDeletion(file.Get())) return false;
  file.Reset();
  if (!MarkForDeletion(staged_directory.Get())) return false;
  staged_directory.Reset();
  return true;
}

bool Discard(const std::filesystem::path& candidate,
             const std::filesystem::path& staging_root) {
  return ValidateStaged(candidate, staging_root, true);
}

bool IsOwned(const std::filesystem::path& candidate,
             const std::filesystem::path& staging_root) {
  return ValidateStaged(candidate, staging_root, false);
}

}  // namespace sybl::picked_file
