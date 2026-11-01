#ifdef NDEBUG
#undef NDEBUG
#endif

#include "archive_path_policy.h"

#define NOMINMAX
#include <windows.h>

#include <winioctl.h>

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

namespace {

using sybl::archive::ArchivePathUse;
using sybl::archive::IsSafeArchiveExchangePath;

std::filesystem::path UniqueRoot() {
  wchar_t temporary[MAX_PATH]{};
  assert(GetTempPathW(MAX_PATH, temporary) > 0);
  return std::filesystem::path(temporary) /
         (L"sybl-archive-path-policy-" +
          std::to_wstring(GetCurrentProcessId()));
}

void WriteByte(const std::filesystem::path& path) {
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  stream.put('x');
  stream.close();
  assert(stream.good());
}

using sybl::archive::IdentityRootOutcome;
using sybl::archive::IdentityRootResolution;
using sybl::archive::IsSameDirectory;
using sybl::archive::ResolveIdentityDataRoot;

bool IsRoot(const IdentityRootResolution& resolution,
            const std::wstring& expected) {
  return resolution.outcome == IdentityRootOutcome::kResolved &&
         resolution.root == expected;
}

bool IsUnresolved(const IdentityRootResolution& resolution) {
  return resolution.outcome == IdentityRootOutcome::kUnresolved &&
         resolution.root.empty();
}

bool IsMismatch(const IdentityRootResolution& resolution) {
  return resolution.outcome == IdentityRootOutcome::kMismatch &&
         resolution.root.empty();
}

void IdentityDataRootNeverLeavesTheEstablishedLocalAppData() {
  using Text = std::optional<std::wstring>;
  const Text env = std::wstring(L"C:\\Users\\a\\AppData\\Local");
  const Text known = std::wstring(L"D:\\Other\\Local");
  const Text absent;
  const Text tooLong = L"C:\\" + std::wstring(MAX_PATH, L'x');
  const Text justUnder = L"C:\\" + std::wstring(MAX_PATH - 4, L'x');
  const Text relative = std::wstring(L"AppData\\Local");
  const Text rooted = std::wstring(L"\\AppData\\Local");
  const Text empty = std::wstring();
  const std::wstring envRoot = L"C:\\Users\\a\\AppData\\Local\\Syb-L";
  const std::wstring knownRoot = L"D:\\Other\\Local\\Syb-L";

  // The same-directory decision is consulted only when both are usable, and
  // then with exactly the two base values.
  int calls = 0;
  std::wstring seenLeft;
  std::wstring seenRight;
  const auto same = [&](const std::wstring& left, const std::wstring& right) {
    ++calls;
    seenLeft = left;
    seenRight = right;
    return true;
  };
  const auto different = [&](const std::wstring& left,
                             const std::wstring& right) {
    ++calls;
    seenLeft = left;
    seenRight = right;
    return false;
  };

  // Both usable and the same directory: the known-folder spelling, the one
  // every other identity store already uses.
  assert(IsRoot(ResolveIdentityDataRoot(env, known, same), knownRoot));
  assert(calls == 1 && seenLeft == *env && seenRight == *known);
  // Character-identical values, the ordinary installation: that same string.
  assert(IsRoot(ResolveIdentityDataRoot(env, env, same), envRoot));
  // A spelling Win32 opens as the same directory through a trailing space
  // (children cannot be created under it) or dot never reaches the root.
  const Text envTrailingSpace = *known + L" ";
  const Text envTrailingDot = *known + L".";
  assert(IsRoot(ResolveIdentityDataRoot(envTrailingSpace, known, same),
                knownRoot));
  assert(IsRoot(ResolveIdentityDataRoot(envTrailingDot, known, same),
                knownRoot));
  // Both usable and different directories: refuse.
  calls = 0;
  assert(IsMismatch(ResolveIdentityDataRoot(env, known, different)));
  assert(calls == 1 && seenLeft == *env && seenRight == *known);

  // Environment unusable and known usable: the known folder, never a mismatch.
  calls = 0;
  for (const Text& unusable : {absent, empty, tooLong, relative, rooted}) {
    assert(IsRoot(ResolveIdentityDataRoot(unusable, known, different),
                  knownRoot));
    assert(IsRoot(ResolveIdentityDataRoot(unusable, known, same), knownRoot));
  }
  // Environment usable and known absent or unusable: the environment root.
  for (const Text& unusable : {absent, empty, tooLong, relative, rooted}) {
    assert(IsRoot(ResolveIdentityDataRoot(env, unusable, different), envRoot));
  }
  assert(IsRoot(ResolveIdentityDataRoot(justUnder, absent, different),
                justUnder.value() + L"\\Syb-L"));
  // Neither usable: no root.
  assert(IsUnresolved(ResolveIdentityDataRoot(absent, absent, same)));
  assert(IsUnresolved(ResolveIdentityDataRoot(tooLong, absent, same)));
  assert(IsUnresolved(ResolveIdentityDataRoot(relative, relative, same)));
  assert(IsUnresolved(ResolveIdentityDataRoot(empty, tooLong, same)));
  assert(IsUnresolved(ResolveIdentityDataRoot(rooted, empty, same)));
  assert(calls == 0);

  // Length boundary: 259 characters is usable, 260 is not.
  const Text exactly259 = L"C:\\" + std::wstring(259 - 3, L'y');
  const Text exactly260 = L"C:\\" + std::wstring(260 - 3, L'y');
  assert(exactly259->size() == 259 && exactly260->size() == 260);
  assert(IsRoot(ResolveIdentityDataRoot(exactly259, known, same), knownRoot));
  assert(IsMismatch(ResolveIdentityDataRoot(exactly259, known, different)));
  assert(IsRoot(ResolveIdentityDataRoot(exactly260, known, different),
                knownRoot));
  assert(IsRoot(ResolveIdentityDataRoot(absent, exactly259, different),
                exactly259.value() + L"\\Syb-L"));
  assert(IsRoot(ResolveIdentityDataRoot(exactly259, exactly260, different),
                exactly259.value() + L"\\Syb-L"));
  assert(IsUnresolved(ResolveIdentityDataRoot(absent, exactly260, same)));

  // No input combination yields a temporary or relative location.
  wchar_t temporary[MAX_PATH]{};
  assert(GetTempPathW(MAX_PATH, temporary) > 0);
  const std::wstring temp_dir(temporary);
  for (bool sameDirectory : {true, false}) {
    const auto check = [sameDirectory](const std::wstring&,
                                       const std::wstring&) {
      return sameDirectory;
    };
    for (const Text& e :
         {env, known, absent, tooLong, relative, rooted, empty}) {
      for (const Text& k :
           {env, known, absent, tooLong, relative, rooted, empty}) {
        const auto resolved = ResolveIdentityDataRoot(e, k, check);
        if (resolved.outcome != IdentityRootOutcome::kResolved) {
          assert(resolved.root.empty());
          continue;
        }
        assert(std::filesystem::path(resolved.root).is_absolute());
        assert(resolved.root.compare(0, temp_dir.size(), temp_dir) != 0);
      }
    }
  }
}

// Creates `link` as a directory junction to `target` without privilege.
bool CreateJunction(const std::filesystem::path& link,
                    const std::filesystem::path& target) {
  if (!CreateDirectoryW(link.c_str(), nullptr)) return false;
  HANDLE handle = CreateFileW(
      link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    RemoveDirectoryW(link.c_str());
    return false;
  }
  const std::wstring substitute = L"\\??\\" + target.wstring();
  const std::wstring print = target.wstring();
  const auto substituteBytes =
      static_cast<USHORT>(substitute.size() * sizeof(wchar_t));
  const auto printBytes = static_cast<USHORT>(print.size() * sizeof(wchar_t));
  // Mount-point layout: offsets and lengths, then both NUL-terminated names.
  const auto dataLength = static_cast<USHORT>(
      4 * sizeof(USHORT) + substituteBytes + sizeof(wchar_t) + printBytes +
      sizeof(wchar_t));
  std::vector<BYTE> buffer(8 + dataLength, 0);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  const USHORT fields[] = {
      0, substituteBytes, static_cast<USHORT>(substituteBytes + sizeof(wchar_t)),
      printBytes};
  std::memcpy(buffer.data(), &tag, sizeof(tag));
  std::memcpy(buffer.data() + 4, &dataLength, sizeof(dataLength));
  std::memcpy(buffer.data() + 8, fields, sizeof(fields));
  std::memcpy(buffer.data() + 16, substitute.data(), substituteBytes);
  std::memcpy(buffer.data() + 16 + substituteBytes + sizeof(wchar_t),
              print.data(), printBytes);
  DWORD returned = 0;
  const bool set = DeviceIoControl(
      handle, FSCTL_SET_REPARSE_POINT, buffer.data(),
      static_cast<DWORD>(buffer.size()), nullptr, 0, &returned, nullptr);
  CloseHandle(handle);
  if (!set) RemoveDirectoryW(link.c_str());
  return set;
}

void SameDirectoryFollowsFileIdentity(const std::filesystem::path& root) {
  const auto local = root / L"LocalAppDataLongName";
  const auto other = root / L"OtherLocalAppData";
  const auto file = root / L"not-a-directory.txt";
  std::filesystem::create_directories(local);
  std::filesystem::create_directories(other);
  WriteByte(file);
  const std::wstring text = local.wstring();

  assert(IsSameDirectory(local, local));
  std::wstring upper = text;
  std::transform(upper.begin(), upper.end(), upper.begin(),
                 [](wchar_t value) { return std::towupper(value); });
  assert(upper != text);
  assert(IsSameDirectory(upper, local));
  assert(IsSameDirectory(local, text + L"\\"));
  assert(IsSameDirectory(text + L"\\", text + L"\\\\"));
  assert(IsSameDirectory(local / L".." / L"LocalAppDataLongName", local));
  assert(IsSameDirectory(local, local / L"."));
  std::wstring forward = text;
  std::replace(forward.begin(), forward.end(), L'\\', L'/');
  assert(IsSameDirectory(forward, local));
  assert(IsSameDirectory(L"\\\\?\\" + text, local));

  wchar_t shortName[MAX_PATH]{};
  const DWORD shortLength = GetShortPathNameW(text.c_str(), shortName, MAX_PATH);
  if (shortLength > 0 && shortLength < MAX_PATH &&
      std::wstring(shortName) != text) {
    assert(IsSameDirectory(std::wstring(shortName), local));
  } else {
    std::fwprintf(stderr, L"SKIP: 8.3 short names unavailable on this volume\n");
  }

  const auto junction = root / L"junction-to-local";
  if (CreateJunction(junction, local)) {
    assert(IsSameDirectory(junction, local));
    assert(!IsSameDirectory(junction, other));
    RemoveDirectoryW(junction.c_str());
  } else {
    std::fwprintf(stderr, L"SKIP: junction could not be created (%lu)\n",
                  GetLastError());
  }
  const auto symlink = root / L"symlink-to-local";
  if (CreateSymbolicLinkW(symlink.c_str(), local.c_str(),
                          SYMBOLIC_LINK_FLAG_DIRECTORY |
                              SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    assert(IsSameDirectory(local, symlink));
    RemoveDirectoryW(symlink.c_str());
  } else {
    std::fwprintf(stderr,
                  L"SKIP: directory symbolic link refused by the platform (%lu)\n",
                  GetLastError());
  }

  // End to end on real directories: a trailing-space spelling of the known
  // folder is the same directory and resolves to the known spelling; a
  // different directory is refused.
  assert(IsSameDirectory(text + L" ", local));
  assert(IsRoot(ResolveIdentityDataRoot(text + L" ", text, IsSameDirectory),
                text + L"\\Syb-L"));
  assert(IsRoot(ResolveIdentityDataRoot(upper, text, IsSameDirectory),
                text + L"\\Syb-L"));
  assert(IsMismatch(
      ResolveIdentityDataRoot(other.wstring(), text, IsSameDirectory)));

  // Paths that cannot be opened fall back to a canonical spelling compare.
  const std::wstring missing = (root / L"missing").wstring();
  std::wstring missingUpper = missing;
  std::transform(missingUpper.begin(), missingUpper.end(),
                 missingUpper.begin(),
                 [](wchar_t value) { return std::towupper(value); });
  assert(IsSameDirectory(missing, missingUpper + L"\\"));
  assert(IsSameDirectory(L"\\\\?\\" + missing, missing + L"\\.\\"));
  assert(!IsSameDirectory(missing, (root / L"missing-too").wstring()));

  assert(!IsSameDirectory(local, other));
  assert(!IsSameDirectory(other, upper));
  assert(!IsSameDirectory(local, root));
  assert(!IsSameDirectory(local, root / L"missing"));
  assert(!IsSameDirectory(root / L"missing", local));
  assert(!IsSameDirectory(file, local));
  assert(!IsSameDirectory(local, file));
  assert(!IsSameDirectory(file, file));
}

}  // namespace

int main() {
  IdentityDataRootNeverLeavesTheEstablishedLocalAppData();
  const auto root = UniqueRoot();
  const auto private_root = root / L"private";
  const auto outside = root / L"outside";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(private_root);
  std::filesystem::create_directories(outside);
  SameDirectoryFollowsFileIdentity(root / L"identity");

  const auto live = private_root / L"archive.gz";
  const auto external = outside / L"backup.gz";
  WriteByte(live);
  WriteByte(external);

  assert(!IsSafeArchiveExchangePath(
      live, private_root, ArchivePathUse::kImportExisting));
  assert(!IsSafeArchiveExchangePath(
      live, private_root, ArchivePathUse::kExportDestination));
  assert(IsSafeArchiveExchangePath(
      external, private_root, ArchivePathUse::kImportExisting));
  assert(IsSafeArchiveExchangePath(
      external, private_root, ArchivePathUse::kExportDestination));
  assert(IsSafeArchiveExchangePath(
      outside / L"new-backup.gz", private_root,
      ArchivePathUse::kExportDestination));
  assert(!IsSafeArchiveExchangePath(
      outside / L"missing.gz", private_root,
      ArchivePathUse::kImportExisting));
  assert(!IsSafeArchiveExchangePath(
      std::filesystem::path(L"relative.gz"), private_root,
      ArchivePathUse::kExportDestination));
  assert(!IsSafeArchiveExchangePath(
      outside / L"backup.gz:stream", private_root,
      ArchivePathUse::kExportDestination));

  const auto hardlink = outside / L"private-hardlink.gz";
  if (CreateHardLinkW(hardlink.c_str(), live.c_str(), nullptr)) {
    assert(!IsSafeArchiveExchangePath(
        hardlink, private_root, ArchivePathUse::kImportExisting));
    assert(!IsSafeArchiveExchangePath(
        hardlink, private_root, ArchivePathUse::kExportDestination));
  }

  const auto alias = outside / L"private-alias.gz";
  if (CreateSymbolicLinkW(
          alias.c_str(), live.c_str(),
          SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    assert(!IsSafeArchiveExchangePath(
        alias, private_root, ArchivePathUse::kImportExisting));
    assert(!IsSafeArchiveExchangePath(
        alias, private_root, ArchivePathUse::kExportDestination));
  }

  std::filesystem::remove_all(root);
}
