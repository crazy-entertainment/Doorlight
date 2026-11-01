#include "remote_control_focus.h"

#include <algorithm>
#include <array>
#include <cwctype>
#include <vector>

namespace sybl::remote {
namespace {

std::wstring BaseName(std::wstring value) {
  const auto slash = value.find_last_of(L"\\/");
  if (slash != std::wstring::npos) value.erase(0, slash + 1);
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return std::towlower(c); });
  return value;
}

}  // namespace

bool IsDeniedForegroundExecutable(const std::wstring& executable_name) {
  static constexpr std::array<const wchar_t*, 8> denied{
      L"credentialuibroker.exe",
      L"1password.exe",
      L"bitwarden.exe",
      L"dashlane.exe",
      L"keepass.exe",
      L"keepassxc.exe",
      L"lastpass.exe",
      L"protonpass.exe",
  };
  const auto name = BaseName(executable_name);
  return std::any_of(denied.begin(), denied.end(),
                     [&name](const wchar_t* candidate) {
                       return name == candidate;
                     });
}

bool OwnerWindowStateAllowsWholeDesktopControl(bool exists,
                                               bool visible,
                                               bool minimized) {
  return exists && visible && !minimized;
}

bool OwnerWindowAllowsWholeDesktopControl(HWND owner) {
  return OwnerWindowStateAllowsWholeDesktopControl(
      owner && IsWindow(owner), owner && IsWindowVisible(owner),
      owner && IsIconic(owner));
}

bool DeniedSensitiveForeground() {
  const auto foreground = GetForegroundWindow();
  if (!foreground) return false;
  DWORD process_id = 0;
  GetWindowThreadProcessId(foreground, &process_id);
  if (!process_id) return false;
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               process_id);
  if (!process) return false;
  std::vector<wchar_t> path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  const bool read = QueryFullProcessImageNameW(
      process, 0, path.data(), &length) != FALSE;
  CloseHandle(process);
  return read &&
      IsDeniedForegroundExecutable(std::wstring(path.data(), length));
}

}  // namespace sybl::remote
