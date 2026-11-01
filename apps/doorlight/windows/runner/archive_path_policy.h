#pragma once

#include <filesystem>
#include <functional>
#include <optional>
#include <string>

namespace sybl::archive {

enum class ArchivePathUse {
  kImportExisting,
  kExportDestination,
};

// Rejects archive import/export paths that can alias Syb-L's private state.
// The caller supplies the app-private root so the policy is independently
// testable. Existing hard-linked files are rejected because canonical path
// checks cannot reveal a second directory entry for the same file.
bool IsSafeArchiveExchangePath(
    const std::filesystem::path& candidate,
    const std::filesystem::path& app_private_root,
    ArchivePathUse use);

// Windows MAX_PATH, duplicated so the resolver stays free of <windows.h>.
inline constexpr size_t kIdentityRootMaxPath = 260;

enum class IdentityRootOutcome {
  kResolved,
  kUnresolved,
  // Both values are usable but name different directories.
  kMismatch,
};

struct IdentityRootResolution {
  IdentityRootOutcome outcome = IdentityRootOutcome::kUnresolved;
  // `<base>\Syb-L`; empty unless `outcome` is kResolved.
  std::wstring root;
};

// Decides whether two usable base paths name the same directory.
using SameDirectoryCheck =
    std::function<bool(const std::wstring&, const std::wstring&)>;

// Resolves the Syb-L identity data root (`<base>\Syb-L`) from the LOCALAPPDATA
// environment value and the LocalAppData known-folder value. The instance
// lock, DPAPI secret and recovery journal always live under the known folder,
// so when both values are usable they must name the same directory (decided
// by `same_directory`); otherwise the outcome is kMismatch and there is no
// root. With the same directory the known-folder spelling is used, so a
// spelling that opens the directory but cannot hold children (a trailing
// space) never becomes the root. A usable environment value alone wins;
// otherwise the known folder. A value is
// unusable when empty, at least MAX_PATH long, or not an absolute path. No
// other source is consulted, so a missing store is never relocated to a
// temporary or relative directory: with neither value usable there is no root.
IdentityRootResolution ResolveIdentityDataRoot(
    const std::optional<std::wstring>& environment_local_app_data,
    const std::optional<std::wstring>& known_folder_local_app_data,
    const SameDirectoryCheck& same_directory);

// True when both paths are existing directories with the same file identity
// (volume serial number and file ID from a handle opened for attributes only).
// A path that exists but is not a directory is never the same. When either
// path cannot be opened, compares canonical, case-insensitive paths with the
// `\\?\` prefix and trailing separators removed.
bool IsSameDirectory(const std::filesystem::path& left,
                     const std::filesystem::path& right);

}  // namespace sybl::archive
