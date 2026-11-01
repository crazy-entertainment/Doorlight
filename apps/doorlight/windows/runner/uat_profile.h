#pragma once

#include <windows.h>
#include <shlobj.h>
#include <cstring>
#include <cwchar>
#include <initializer_list>
#include <string>

namespace sybl::uat {

#ifdef SYBL_VISUAL_UAT
inline std::wstring profile_root;

inline bool PlainDirectory(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
      !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
}

inline bool PlainTree(const std::wstring& path, unsigned depth = 0) {
  if (depth > 64 || !PlainDirectory(path)) return false;
  WIN32_FIND_DATAW entry{};
  HANDLE search = FindFirstFileW((path + L"\\*").c_str(), &entry);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool okay = true;
  do {
    if (std::wcscmp(entry.cFileName, L".") == 0 || std::wcscmp(entry.cFileName, L"..") == 0) continue;
    if ((entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !PlainTree(path + L"\\" + entry.cFileName, depth + 1))) { okay = false; break; }
  } while (FindNextFileW(search, &entry));
  if (okay && GetLastError() != ERROR_NO_MORE_FILES) okay = false;
  FindClose(search);
  return okay;
}

inline bool InitializeProfile() {
  if (!profile_root.empty()) return true;
  wchar_t value[32768]{};
  const DWORD length = GetEnvironmentVariableW(L"DOORLIGHT_UAT_ROOT", value, 32768);
  if (!length || length >= 32768) return false;
  const std::wstring candidate(value, length);
  const std::wstring base = SYBL_VISUAL_UAT_BASE;
  if (candidate.size() != base.size() + 17 ||
      _wcsnicmp(candidate.c_str(), base.c_str(), base.size()) != 0 ||
      candidate[base.size()] != L'\\') return false;
  const auto name = candidate.substr(base.size() + 1);
  for (size_t i = 0; i < name.size(); ++i) {
    if (!((name[i] >= L'0' && name[i] <= L'9') || (name[i] >= L'a' && name[i] <= L'f'))) return false;
  }
  // Reject junctions and symlinks throughout the dedicated profile's ancestry.
  for (size_t i = 3; i <= candidate.size(); ++i) {
    if (i == candidate.size() || candidate[i] == L'\\') {
      if (!PlainDirectory(candidate.substr(0, i))) return false;
    }
  }
  const std::wstring marker = candidate + L"\\profile.marker";
  const DWORD marker_attributes = GetFileAttributesW(marker.c_str());
  if (marker_attributes == INVALID_FILE_ATTRIBUTES || (marker_attributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) return false;
  HANDLE file = CreateFileW(marker.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  char content[32]{};
  DWORD read = 0;
  constexpr char expected[] = "doorlight-visual-uat-v1\n";
  const bool marked = ReadFile(file, content, sizeof(content), &read, nullptr) &&
      read == sizeof(expected) - 1 && std::memcmp(content, expected, sizeof(expected) - 1) == 0;
  CloseHandle(file);
  if (!marked || !PlainTree(candidate)) return false;
  for (const auto* child : {L"LocalAppData", L"RoamingAppData", L"Downloads", L"Documents", L"Pictures", L"Videos", L"Temp"}) {
    const auto directory = candidate + L"\\" + child;
    if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
    if (!PlainDirectory(directory)) return false;
  }
  if (!SetEnvironmentVariableW(L"LOCALAPPDATA", (candidate + L"\\LocalAppData").c_str()) ||
      !SetEnvironmentVariableW(L"APPDATA", (candidate + L"\\RoamingAppData").c_str()) ||
      !SetEnvironmentVariableW(L"USERPROFILE", candidate.c_str()) ||
      !SetEnvironmentVariableW(L"TEMP", (candidate + L"\\Temp").c_str()) ||
      !SetEnvironmentVariableW(L"TMP", (candidate + L"\\Temp").c_str())) return false;
  profile_root = candidate;
  return true;
}

inline HRESULT KnownFolderPath(REFKNOWNFOLDERID folder, DWORD, HANDLE, PWSTR* output) {
  if (!output) return E_POINTER;
  *output = nullptr;
  if (profile_root.empty()) return E_ACCESSDENIED;
  const wchar_t* child = nullptr;
  if (IsEqualGUID(folder, FOLDERID_LocalAppData)) child = L"LocalAppData";
  else if (IsEqualGUID(folder, FOLDERID_RoamingAppData)) child = L"RoamingAppData";
  else if (IsEqualGUID(folder, FOLDERID_Downloads)) child = L"Downloads";
  else if (IsEqualGUID(folder, FOLDERID_Documents)) child = L"Documents";
  else if (IsEqualGUID(folder, FOLDERID_Pictures)) child = L"Pictures";
  else if (IsEqualGUID(folder, FOLDERID_Videos)) child = L"Videos";
  else return E_ACCESSDENIED;
  const auto directory = profile_root + L"\\" + child;
  if (!PlainDirectory(directory)) return E_ACCESSDENIED;
  const auto size = (directory.size() + 1) * sizeof(wchar_t);
  *output = static_cast<PWSTR>(CoTaskMemAlloc(size));
  if (!*output) return E_OUTOFMEMORY;
  std::memcpy(*output, directory.c_str(), size);
  return S_OK;
}
#else
inline HRESULT KnownFolderPath(REFKNOWNFOLDERID folder, DWORD flags, HANDLE token, PWSTR* output) {
  return SHGetKnownFolderPath(folder, flags, token, output);
}
#endif

}  // namespace sybl::uat
