#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "window_presentation.h"
#include "invite_link_win32.h"
#include "utils.h"
#include "window_bounds.h"
#include "uat_profile.h"

namespace {

HANDLE AcquireInstanceLock() {
  PWSTR local = nullptr;
  if (FAILED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                    nullptr, &local)) ||
      !local) {
    return INVALID_HANDLE_VALUE;
  }
  std::wstring directory(local);
  ::CoTaskMemFree(local);
  directory += L"\\Syb-L";
  if (!::CreateDirectoryW(directory.c_str(), nullptr) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return INVALID_HANDLE_VALUE;
  }
  const DWORD attributes = ::GetFileAttributesW(directory.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return INVALID_HANDLE_VALUE;
  }
  return ::CreateFileW(
      (directory + L"\\instance.lock").c_str(),
      GENERIC_READ | GENERIC_WRITE,
      0, nullptr, OPEN_ALWAYS,
      FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
#ifdef SYBL_VISUAL_UAT
  if (!sybl::uat::InitializeProfile()) return EXIT_FAILURE;
#endif
  if (!::SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
                                  LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    return EXIT_FAILURE;
  }
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
#ifndef SYBL_VISUAL_UAT
  const auto invite =
      sybl::invite_link::FindInviteArgument(command_line_arguments);
#endif
  // Single-instance guard. libjami does NOT lock its data dir (the daemon's .ring.pid is never enforced), so two
  // Syb-L processes writing the same %LOCALAPPDATA%\Syb-L\jami\dring.yml concurrently produce malformed,
  // interleaved YAML — the daemon then fails to parse it ("invalid node") and creates a BRAND-NEW account,
  // silently losing the user's identity. An exclusive file in that exact per-user root crosses logon/RDP session
  // namespaces; a second launch surfaces the existing same-session window when possible, then exits.
  HANDLE instance_lock = AcquireInstanceLock();
  // Fail CLOSED: if the lock is held OR could not be opened, do NOT boot a second daemon onto the shared data dir.
  // Surface the existing window if we can find it
  // and exit. (Booting on an ambiguous guard is exactly what corrupts dring.yml and loses the identity.)
  if (instance_lock == INVALID_HANDLE_VALUE) {
#ifndef SYBL_VISUAL_UAT
    if (HWND existing = sybl::invite_link::FindMainWindow()) {
      // The running instance owns every reveal (cover, show, foreground); an
      // unacknowledged request shows nothing.
      sybl::invite_link::ForwardAndRequestReveal(existing, invite);
    }
#endif
#ifdef SYBL_VISUAL_UAT
    return EXIT_FAILURE;
#else
    return EXIT_SUCCESS;
#endif
  }
#ifndef SYBL_VISUAL_UAT
  sybl::invite_link::RegisterCurrentExecutable();
#endif

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Start as a compact tray companion. This is a logical size;
  // Win32Window::Create scales it by the monitor DPI.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(sybl::window::kDefaultWindowWidth,
                         sybl::window::kDefaultWindowHeight);
  if (!window.Create(L"Doorlight", origin, size)) {
    ::CloseHandle(instance_lock);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
#ifndef SYBL_VISUAL_UAT
  if (!sybl::invite_link::MarkMainWindow(window.GetHandle())) {
    ::CloseHandle(instance_lock);
    return EXIT_FAILURE;
  }
#endif

  // Reopen where the user last left the window. Saved bounds are PHYSICAL pixels, so
  // they are applied directly rather than through Create()'s logical->DPI scaling; a
  // window saved on a monitor that has since been unplugged, shrunk, or rescaled is
  // clamped back into view (or discarded) by ChooseRestoreBounds.
  if (HWND hwnd = window.GetHandle()) {
    std::optional<sybl::window::Bounds> restored;
    if (const auto saved = sybl::window::LoadBounds()) {
      std::vector<sybl::window::WorkArea> areas;
      ::EnumDisplayMonitors(
          nullptr, nullptr,
          [](HMONITOR monitor, HDC, LPRECT, LPARAM param) -> BOOL {
            MONITORINFO info{};
            info.cbSize = sizeof(info);
            if (::GetMonitorInfo(monitor, &info)) {
              reinterpret_cast<std::vector<sybl::window::WorkArea>*>(param)
                  ->push_back({info.rcWork.left, info.rcWork.top,
                               info.rcWork.right, info.rcWork.bottom});
            }
            return TRUE;
          },
          reinterpret_cast<LPARAM>(&areas));
      MINMAXINFO limits{};
      ::SendMessageW(hwnd, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits));
      restored = sybl::window::ChooseRestoreBounds(
          *saved, areas, limits.ptMinTrackSize.x, limits.ptMinTrackSize.y);
    }

    if (restored) {
      ::SetWindowPos(hwnd, nullptr, restored->x, restored->y, restored->width,
                     restored->height, SWP_NOZORDER | SWP_NOACTIVATE);
      if (restored->maximized) ::ShowWindow(hwnd, SW_MAXIMIZE);
    } else {
      // First run, or an unusable saved placement: leave a small, DPI-scaled
      // gap between the visible frame and the primary work area's tray corner.
      window.SetDefaultCornerGap(8);
    }
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(instance_lock);
  return EXIT_SUCCESS;
}
