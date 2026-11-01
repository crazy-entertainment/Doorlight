#include "archive_path_policy.h"

#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <cstring>
#include <cwctype>
#include <system_error>

namespace sybl::archive {
namespace {

bool SameComponent(const std::filesystem::path& left,
                   const std::filesystem::path& right) {
  auto left_text = left.wstring();
  auto right_text = right.wstring();
  std::transform(left_text.begin(), left_text.end(), left_text.begin(),
                 [](wchar_t value) { return std::towlower(value); });
  std::transform(right_text.begin(), right_text.end(), right_text.begin(),
                 [](wchar_t value) { return std::towlower(value); });
  return left_text == right_text;
}

bool IsAtOrBelow(const std::filesystem::path& candidate,
                 const std::filesystem::path& root) {
  auto candidate_part = candidate.begin();
  for (auto root_part = root.begin(); root_part != root.end(); ++root_part) {
    if (candidate_part == candidate.end() ||
        !SameComponent(*candidate_part, *root_part)) {
      return false;
    }
    ++candidate_part;
  }
  return true;
}

bool ExistingFileHasOneName(const std::filesystem::path& path) {
  HANDLE file = CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION information{};
  const bool loaded = GetFileInformationByHandle(file, &information);
  CloseHandle(file);
  return loaded && information.nNumberOfLinks == 1;
}

enum class DirectoryState { kOpened, kNotDirectory, kUnopened };

struct DirectoryIdentity {
  bool has_file_id = false;
  ULONGLONG file_id_volume = 0;
  unsigned char file_id[16]{};
  DWORD volume = 0;
  ULONGLONG file_index = 0;
};

// Opens `path` for attributes only, following junctions and symbolic links.
DirectoryState ReadDirectoryIdentity(const std::filesystem::path& path,
                                     DirectoryIdentity& identity) {
  HANDLE handle = CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      return DirectoryState::kNotDirectory;
    }
    return DirectoryState::kUnopened;
  }
  BY_HANDLE_FILE_INFORMATION information{};
  const bool loaded = GetFileInformationByHandle(handle, &information);
  FILE_ID_INFO file_id{};
  identity.has_file_id =
      loaded && GetFileInformationByHandleEx(handle, FileIdInfo, &file_id,
                                             sizeof(file_id));
  CloseHandle(handle);
  if (!loaded) return DirectoryState::kUnopened;
  if ((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
    return DirectoryState::kNotDirectory;
  if (identity.has_file_id) {
    identity.file_id_volume = file_id.VolumeSerialNumber;
    static_assert(sizeof(identity.file_id) == sizeof(file_id.FileId));
    std::memcpy(identity.file_id, &file_id.FileId, sizeof(identity.file_id));
  }
  identity.volume = information.dwVolumeSerialNumber;
  identity.file_index =
      (static_cast<ULONGLONG>(information.nFileIndexHigh) << 32) |
      information.nFileIndexLow;
  return DirectoryState::kOpened;
}

std::wstring WithoutVerbatimPrefix(const std::wstring& text) {
  if (text.rfind(L"\\\\?\\UNC\\", 0) == 0) return L"\\\\" + text.substr(8);
  if (text.rfind(L"\\\\?\\", 0) == 0) return text.substr(4);
  return text;
}

// Canonical spelling used only when a directory cannot be opened.
std::wstring ComparableDirectoryPath(const std::filesystem::path& path) {
  const std::filesystem::path plain(WithoutVerbatimPrefix(path.wstring()));
  std::error_code error;
  auto resolved = std::filesystem::weakly_canonical(plain, error);
  if (error) resolved = plain;
  auto text = WithoutVerbatimPrefix(
      resolved.lexically_normal().make_preferred().wstring());
  while (text.size() > 1 && text.back() == L'\\' &&
         !(text.size() == 3 && text[1] == L':')) {
    text.pop_back();
  }
  return text;
}

}  // namespace

bool IsSafeArchiveExchangePath(
    const std::filesystem::path& candidate,
    const std::filesystem::path& app_private_root,
    ArchivePathUse use) {
  if (candidate.empty() || app_private_root.empty() ||
      !candidate.is_absolute() || !app_private_root.is_absolute()) {
    return false;
  }
  const auto filename = candidate.filename().wstring();
  if (filename.empty() || filename == L"." || filename == L".." ||
      filename.find(L':') != std::wstring::npos) {
    return false;
  }

  std::error_code error;
  const bool exists = std::filesystem::exists(candidate, error);
  if (error) return false;
  if (use == ArchivePathUse::kImportExisting && !exists) return false;
  if (exists && !std::filesystem::is_regular_file(candidate, error))
    return false;
  if (error) return false;

  const auto root =
      std::filesystem::weakly_canonical(app_private_root, error);
  if (error) return false;
  const auto resolved = std::filesystem::weakly_canonical(candidate, error);
  if (error || IsAtOrBelow(resolved, root)) return false;

  const auto parent = resolved.parent_path();
  if (parent.empty() || !std::filesystem::is_directory(parent, error) ||
      error) {
    return false;
  }
  if (exists && !ExistingFileHasOneName(resolved)) return false;
  return true;
}

IdentityRootResolution ResolveIdentityDataRoot(
    const std::optional<std::wstring>& environment_local_app_data,
    const std::optional<std::wstring>& known_folder_local_app_data,
    const SameDirectoryCheck& same_directory) {
  const auto usable = [](const std::optional<std::wstring>& value) {
    return value && !value->empty() && value->size() < kIdentityRootMaxPath &&
           std::filesystem::path(*value).is_absolute();
  };
  const bool environment_usable = usable(environment_local_app_data);
  const bool known_usable = usable(known_folder_local_app_data);
  if (environment_usable && known_usable) {
    if (!same_directory(*environment_local_app_data,
                        *known_folder_local_app_data)) {
      return {IdentityRootOutcome::kMismatch, {}};
    }
    return {IdentityRootOutcome::kResolved,
            *known_folder_local_app_data + L"\\Syb-L"};
  }
  if (environment_usable) {
    return {IdentityRootOutcome::kResolved,
            *environment_local_app_data + L"\\Syb-L"};
  }
  if (known_usable) {
    return {IdentityRootOutcome::kResolved,
            *known_folder_local_app_data + L"\\Syb-L"};
  }
  return {IdentityRootOutcome::kUnresolved, {}};
}

bool IsSameDirectory(const std::filesystem::path& left,
                     const std::filesystem::path& right) {
  DirectoryIdentity left_identity;
  DirectoryIdentity right_identity;
  const auto left_state = ReadDirectoryIdentity(left, left_identity);
  const auto right_state = ReadDirectoryIdentity(right, right_identity);
  if (left_state == DirectoryState::kNotDirectory ||
      right_state == DirectoryState::kNotDirectory) {
    return false;
  }
  if (left_state == DirectoryState::kOpened &&
      right_state == DirectoryState::kOpened) {
    if (left_identity.has_file_id && right_identity.has_file_id) {
      return left_identity.file_id_volume == right_identity.file_id_volume &&
             std::memcmp(left_identity.file_id, right_identity.file_id,
                         sizeof(left_identity.file_id)) == 0;
    }
    return left_identity.volume == right_identity.volume &&
           left_identity.file_index == right_identity.file_index;
  }
  const auto left_text = ComparableDirectoryPath(left);
  const auto right_text = ComparableDirectoryPath(right);
  return !left_text.empty() && !right_text.empty() &&
         CompareStringOrdinal(left_text.c_str(),
                              static_cast<int>(left_text.size()),
                              right_text.c_str(),
                              static_cast<int>(right_text.size()),
                              TRUE) == CSTR_EQUAL;
}

}  // namespace sybl::archive
