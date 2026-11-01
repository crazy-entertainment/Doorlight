#include "presence_metadata.h"

#include "timeline_wire.h"

#include <algorithm>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace sybl::presence_metadata {
namespace {

std::string WideToUtf8(std::wstring_view value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<std::size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), size,
                          nullptr, nullptr) != size) {
    return {};
  }
  return result;
}

std::wstring VersionString(const std::wstring& path,
                           const wchar_t* field) {
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
  if (size == 0) return {};
  std::vector<unsigned char> data(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return {};

  struct Translation {
    WORD language;
    WORD code_page;
  };
  Translation* translations = nullptr;
  UINT translation_bytes = 0;
  std::vector<Translation> fallbacks{{0x0409, 0x04b0}};
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                      reinterpret_cast<void**>(&translations),
                      &translation_bytes) ||
      translations == nullptr ||
      translation_bytes < sizeof(Translation)) {
    translations = fallbacks.data();
    translation_bytes = static_cast<UINT>(sizeof(Translation));
  }

  const auto count = translation_bytes / sizeof(Translation);
  for (UINT index = 0; index < count; ++index) {
    wchar_t query[128]{};
    _snwprintf_s(query, _countof(query), _TRUNCATE,
                 L"\\StringFileInfo\\%04x%04x\\%ls",
                 translations[index].language, translations[index].code_page,
                 field);
    wchar_t* text = nullptr;
    UINT length = 0;
    if (VerQueryValueW(data.data(), query,
                       reinterpret_cast<void**>(&text), &length) &&
        text != nullptr && length > 1) {
      return std::wstring(text, length - 1);
    }
  }
  return {};
}

}  // namespace

std::string SanitizeActivity(std::string_view value) {
  const auto measure = timeline::MeasureUtf8(value, 4096);
  if (!measure) return {};

  std::string result;
  result.reserve(std::min(value.size(), kMaxActivityUtf8Bytes));
  bool pending_space = false;
  for (std::size_t index = 0; index < value.size();) {
    const auto first = static_cast<unsigned char>(value[index]);
    std::size_t width = 1;
    if ((first & 0xe0) == 0xc0) width = 2;
    else if ((first & 0xf0) == 0xe0) width = 3;
    else if ((first & 0xf8) == 0xf0) width = 4;

    if (first < 0x80) {
      const char ascii = static_cast<char>(first);
      if (first <= 0x20 || first == 0x7f || ascii == '"' ||
          ascii == '\\') {
        pending_space = !result.empty();
        ++index;
        continue;
      }
    }
    if (pending_space) {
      if (result.size() + 1 > kMaxActivityUtf8Bytes) break;
      result.push_back(' ');
      pending_space = false;
    }
    if (result.size() + width > kMaxActivityUtf8Bytes) break;
    result.append(value.substr(index, width));
    index += width;
  }
  while (!result.empty() && result.back() == ' ') result.pop_back();
  return result;
}

std::string ForegroundApplicationLabel(std::uint32_t own_process_id) {
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr) return {};
  DWORD process_id = 0;
  GetWindowThreadProcessId(foreground, &process_id);
  if (process_id == 0 || process_id == own_process_id) return {};

  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) return {};
  std::wstring path(32768, L'\0');
  DWORD path_size = static_cast<DWORD>(path.size());
  const bool queried =
      QueryFullProcessImageNameW(process, 0, path.data(), &path_size) != FALSE;
  CloseHandle(process);
  if (!queried || path_size == 0) return {};
  path.resize(path_size);

  std::wstring label = VersionString(path, L"ProductName");
  if (label.empty()) label = VersionString(path, L"FileDescription");
  if (label.empty()) label = std::filesystem::path(path).stem().wstring();
  return SanitizeActivity(WideToUtf8(label));
}

}  // namespace sybl::presence_metadata
