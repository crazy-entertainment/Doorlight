#include "window_bounds.h"

#include <windows.h>

#include <cstdint>
#include "uat_profile.h"

#ifdef SYBL_VISUAL_UAT
namespace sybl::window {
std::optional<Bounds> LoadBounds() {
  if (sybl::uat::profile_root.empty()) return std::nullopt;
  const auto filename = sybl::uat::profile_root + L"\\window-bounds.bin";
  const DWORD attributes = GetFileAttributesW(filename.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return std::nullopt;
  HANDLE file = CreateFileW(filename.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::nullopt;
  DWORD values[6]{}, read = 0;
  const bool okay = GetFileSize(file, nullptr) == sizeof(values) &&
      ReadFile(file, values, sizeof(values), &read, nullptr) && read == sizeof(values) && values[0] == 1;
  CloseHandle(file);
  if (!okay) return std::nullopt;
  return Bounds{static_cast<int>(values[1]), static_cast<int>(values[2]), static_cast<int>(values[3]), static_cast<int>(values[4]), values[5] != 0};
}

bool SaveBounds(const Bounds& bounds) {
  if (sybl::uat::profile_root.empty()) return false;
  const auto filename = sybl::uat::profile_root + L"\\window-bounds.bin";
  const auto temporary = filename + L".tmp";
  for (const auto& candidate : {filename, temporary}) {
    const DWORD attributes = GetFileAttributesW(candidate.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
  }
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  const DWORD values[6]{1, static_cast<DWORD>(bounds.x), static_cast<DWORD>(bounds.y), static_cast<DWORD>(bounds.width), static_cast<DWORD>(bounds.height), bounds.maximized ? 1u : 0u};
  DWORD written = 0;
  const bool okay = WriteFile(file, values, sizeof(values), &written, nullptr) && written == sizeof(values) && FlushFileBuffers(file);
  CloseHandle(file);
  return okay && MoveFileExW(temporary.c_str(), filename.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}
}  // namespace sybl::window
#else

namespace sybl::window {
namespace {

constexpr wchar_t kKey[] = L"Software\\Syb-L\\Window";

bool ReadDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD size = sizeof(DWORD);
  DWORD type = 0;
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<LPBYTE>(value), &size) ==
      ERROR_SUCCESS &&
      type == REG_DWORD && size == sizeof(DWORD);
}

bool WriteDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value),
                        sizeof(value)) == ERROR_SUCCESS;
}

}  // namespace

std::optional<Bounds> LoadBounds() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kKey, 0, KEY_QUERY_VALUE, &key) !=
      ERROR_SUCCESS) {
    return std::nullopt;
  }
  DWORD x = 0, y = 0, width = 0, height = 0, maximized = 0;
  // Every field must be present and well typed. A partially written key is
  // treated as absent rather than as a rectangle with default components.
  const bool complete = ReadDword(key, L"X", &x) && ReadDword(key, L"Y", &y) &&
      ReadDword(key, L"Width", &width) && ReadDword(key, L"Height", &height) &&
      ReadDword(key, L"Maximized", &maximized);
  RegCloseKey(key);
  if (!complete) return std::nullopt;

  Bounds bounds;
  bounds.x = static_cast<int>(static_cast<std::int32_t>(x));
  bounds.y = static_cast<int>(static_cast<std::int32_t>(y));
  bounds.width = static_cast<int>(static_cast<std::int32_t>(width));
  bounds.height = static_cast<int>(static_cast<std::int32_t>(height));
  bounds.maximized = maximized != 0;
  return bounds;
}

bool SaveBounds(const Bounds& bounds) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const bool written =
      WriteDword(key, L"X", static_cast<DWORD>(bounds.x)) &&
      WriteDword(key, L"Y", static_cast<DWORD>(bounds.y)) &&
      WriteDword(key, L"Width", static_cast<DWORD>(bounds.width)) &&
      WriteDword(key, L"Height", static_cast<DWORD>(bounds.height)) &&
      WriteDword(key, L"Maximized", bounds.maximized ? 1u : 0u);
  RegCloseKey(key);
  return written;
}

}  // namespace sybl::window
#endif
