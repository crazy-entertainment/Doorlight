#include "invite_link_win32.h"

#include <algorithm>
#include <vector>

#include "window_presentation.h"

namespace sybl::invite_link {
namespace {

bool SetRegistryString(HKEY key, const wchar_t* name,
                       const std::wstring& value) {
  return RegSetValueExW(
             key, name, 0, REG_SZ,
             reinterpret_cast<const BYTE*>(value.c_str()),
             static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

}  // namespace

bool IsInviteUri(std::string_view value) {
  const std::string_view prefix = value.substr(0, 12) == "doorlight://"
                                      ? "doorlight://add/"
                                      : "sybl://add/";
  if (value.size() <= prefix.size() || value.size() > kMaxUriBytes ||
      value.substr(0, prefix.size()) != prefix) {
    return false;
  }
  return std::none_of(value.begin(), value.end(), [](unsigned char value) {
    return value < 0x20 || value == 0x7f;
  });
}

std::optional<std::string> FindInviteArgument(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (IsInviteUri(argument)) return argument;
  }
  return std::nullopt;
}

namespace {
bool RegisterScheme(const wchar_t* path, const std::wstring& executable) {
  HKEY scheme = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0,
                      nullptr, 0, KEY_SET_VALUE | KEY_CREATE_SUB_KEY, nullptr,
                      &scheme, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const bool root_ok =
      SetRegistryString(scheme, nullptr, L"URL:Doorlight friend invite") &&
      SetRegistryString(scheme, L"URL Protocol", L"");
  HKEY command = nullptr;
  const bool command_open =
      RegCreateKeyExW(scheme, L"shell\\open\\command", 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &command, nullptr) ==
      ERROR_SUCCESS;
  const std::wstring command_value =
      L"\"" + executable + L"\" \"%1\"";
  const bool command_ok =
      command_open && SetRegistryString(command, nullptr, command_value);
  if (command) RegCloseKey(command);
  RegCloseKey(scheme);
  return root_ok && command_ok;
}
}  // namespace

bool RegisterCurrentExecutable() {
  std::wstring executable(32768, L'\0');
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) return false;
  executable.resize(length);
  const bool legacy = RegisterScheme(L"Software\\Classes\\sybl", executable);
  const bool alias = RegisterScheme(L"Software\\Classes\\doorlight", executable);
  return legacy && alias;
}

bool MarkMainWindow(HWND window) {
  return window && SetPropW(window, kWindowIdentity,
                           reinterpret_cast<HANDLE>(1)) != 0;
}

HWND FindMainWindow() {
  HWND found = nullptr;
  EnumWindows([](HWND window, LPARAM context) -> BOOL {
    if (!GetPropW(window, kWindowIdentity)) return TRUE;
    *reinterpret_cast<HWND*>(context) = window;
    return FALSE;
  }, reinterpret_cast<LPARAM>(&found));
  return found ? found : FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"sybl");
}

bool ForwardToWindow(HWND window, const std::string& uri) {
  if (window == nullptr || !IsInviteUri(uri)) return false;
  COPYDATASTRUCT copy{};
  copy.dwData = static_cast<ULONG_PTR>(kCopyDataId);
  copy.cbData = static_cast<DWORD>(uri.size() + 1);
  copy.lpData = const_cast<char*>(uri.c_str());
  DWORD_PTR result = 0;
  return SendMessageTimeoutW(
             window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy),
             SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000, &result) != 0 &&
         result != 0;
}

bool RequestReveal(HWND window) {
  if (window == nullptr) return false;
  const UINT message = sybl::window::RevealRequestMessage();
  if (message == 0) return false;
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  if (process != 0) AllowSetForegroundWindow(process);
  DWORD_PTR result = 0;
  return SendMessageTimeoutW(window, message, 0, 0,
                             SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000, &result) != 0 &&
         result != 0;
}

bool ForwardAndRequestReveal(HWND window,
                             const std::optional<std::string>& invite) {
  if (window == nullptr) return false;
  if (invite) ForwardToWindow(window, *invite);
  return RequestReveal(window);
}

}  // namespace sybl::invite_link
